"""OAuth-compatible transport and an inert hosted button for GhostID.
Existing JSON/legacy endpoints are preserved. This is not OpenID Connect.
"""
import base64
import hashlib
import html
import json
import secrets
import time
from urllib.parse import parse_qsl

from fastapi import APIRouter, Request, HTTPException
from fastapi.responses import JSONResponse, RedirectResponse, HTMLResponse, Response
from pydantic import ValidationError
from starlette.concurrency import run_in_threadpool
from ecos_core import service_sso as sso

router = APIRouter(prefix="/api/sso", tags=["GhostID OAuth"])
HEADERS = {"Cache-Control": "no-store", "Pragma": "no-cache", "Referrer-Policy": "no-referrer"}

def error(code, status=400):
    return JSONResponse({"error": code}, status_code=status, headers=HEADERS)

def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate parameter")
        result[key] = value
    return result

async def form(request):
    if request.headers.get("content-type", "").split(";")[0].strip().lower() != "application/x-www-form-urlencoded":
        raise ValueError("Form content type required")
    raw = bytearray()
    async for chunk in request.stream():
        raw.extend(chunk)
        if len(raw) > 8192:
            raise ValueError("Request too large")
    return unique_pairs(parse_qsl(raw.decode("utf-8"), keep_blank_values=True, max_num_fields=12))

@router.get("/oauth/authorize")
async def authorize(request: Request):
    try:
        if len(request.url.query) > 8192:
            raise ValueError()
        values = unique_pairs(request.query_params.multi_items())
        if values.pop("response_type", None) != "code":
            return error("unsupported_response_type")
        scope = values.pop("scope", "identity")
        if not scope or set(values) - {"client_id", "redirect_uri", "state", "code_challenge", "code_challenge_method", "prompt"}:
            raise ValueError()
        if not values.get("redirect_uri"):
            raise ValueError()
        body = sso.EntranceBody(**values, scopes=scope.split(" "))
        data = await run_in_threadpool(sso.entrance, body, request)
        return RedirectResponse(data["authorization_url"], status_code=302, headers=HEADERS)
    except (ValueError, ValidationError, sso.SSODataError):
        return error("invalid_request")
    except HTTPException as exc:
        return error("access_denied" if exc.status_code == 403 else "invalid_request",
                     429 if exc.status_code == 429 else 400)

@router.post("/oauth/token")
async def token(request: Request):
    try:
        values = await form(request)
        if values.get("grant_type") != "authorization_code":
            return error("unsupported_grant_type")
        body = sso.TokenBody(**values)
        data = await run_in_threadpool(sso.exchange_token, body, request)
        return JSONResponse(data, headers=HEADERS)
    except (ValueError, ValidationError, sso.SSODataError):
        return error("invalid_request")
    except HTTPException as exc:
        return error("invalid_grant", 429 if exc.status_code == 429 else 400)

@router.post("/oauth/revoke")
async def revoke(request: Request):
    try:
        values = await form(request)
        if set(values) - {"token", "client_id", "token_type_hint"}:
            raise ValueError()
        client_id, value = values.get("client_id", ""), values.get("token", "")
        if not sso._ID.fullmatch(client_id) or not sso._OPAQUE.fullmatch(value):
            raise ValueError()
        await run_in_threadpool(revoke_token, request, client_id, value)
        return Response(status_code=200, headers=HEADERS)
    except ValueError:
        return error("invalid_request")
    except HTTPException as exc:
        return error("invalid_client", 429 if exc.status_code == 429 else 400)

def revoke_token(request, client_id, value):
    sso._limit(request, "revoke")
    with sso._db() as connection:
        config, _ = sso._client(connection, client_id)
        sso._check_origin(request, config)
        connection.execute("DELETE FROM access_tokens WHERE client_id=? AND token_hash=?", (client_id, sso._hash(value)))

@router.delete("/grants/{client_id}")
def revoke_grant(client_id: str, request: Request):
    user = sso._member(request)
    sso._limit(request, "revoke-grant", 30)
    with sso._db() as connection:
        config, _ = sso._client(connection, client_id)
        sso._check_origin(request, config, local_only=True)
        connection.execute("BEGIN IMMEDIATE")
        grant = connection.execute("SELECT grant_id FROM authorization_grants WHERE user_id=? AND client_id=?",
                                   (int(user["id"]), client_id)).fetchone()
        if grant:
            from ecos_core.sso_events import queue_revocation
            queue_revocation(connection, config, int(user["id"]), grant["grant_id"])
        connection.execute("DELETE FROM authorization_grants WHERE user_id=? AND client_id=?", (int(user["id"]), client_id))
        connection.execute("DELETE FROM consents WHERE user_id=? AND client_id=?", (int(user["id"]), client_id))
        connection.execute("DELETE FROM access_tokens WHERE user_id=? AND client_id=?", (int(user["id"]), client_id))
        connection.execute("DELETE FROM entrances WHERE user_id=? AND client_id=?", (int(user["id"]), client_id))
    return Response(status_code=204, headers=HEADERS)

STYLE = "html,body{margin:0;background:transparent;font-family:system-ui,sans-serif}a{box-sizing:border-box;display:flex;align-items:center;justify-content:center;gap:10px;min-height:52px;width:100%;padding:10px 18px;border:0;border-radius:14px;background:#5b21b6;color:#fff;text-decoration:none;font-size:16px;font-weight:650}a:hover{background:#6d28d9}a:focus-visible{outline:3px solid #c4b5fd;outline-offset:-4px}svg{width:32px;height:32px;flex:none}"
STYLE_HASH = base64.b64encode(hashlib.sha256(STYLE.encode()).digest()).decode()

@router.get("/widget/{client_id}")
def widget(client_id: str, request: Request):
    sso._limit(request, "widget", 120)
    if request.url.query:
        raise HTTPException(400, "Widget does not accept destination parameters")
    with sso._db() as connection:
        config, _ = sso._client(connection, client_id)
    start = config.get("login_start_uri", "")
    if config["transport"] != "authorization-code" or not start:
        raise HTTPException(409, "Widget is not configured for this service")
    ancestors = " ".join(sorted({sso._origin(url) for url in config["redirect_uris"]}))
    headers = {**HEADERS, "X-Content-Type-Options": "nosniff",
               "Content-Security-Policy": "default-src 'none'; style-src 'sha256-" + STYLE_HASH + "'; base-uri 'none'; form-action 'none'; frame-ancestors " + ancestors,
               "Permissions-Policy": "geolocation=(), camera=(), microphone=()"}
    markup = '<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Войти через GhostID</title><style>' + STYLE + '</style><a target="_top" rel="noreferrer" href="' + html.escape(start, quote=True) + '" aria-label="Войти в ' + html.escape(config["name"], quote=True) + ' через GhostID"><svg aria-hidden="true" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="currentColor" transform="translate(2 1) scale(0.024) translate(-352 -322)" d="M 745.63 341.18 C 750.65 340.87 755.71 340.69 760.78 340.64 C 765.84 340.59 770.94 340.67 776.03 340.87 C 781.11 341.07 786.22 341.4 791.29 341.85 C 796.36 342.3 801.43 342.87 806.45 343.56 C 811.47 344.25 816.47 345.06 821.41 345.98 C 826.35 346.91 831.25 347.95 836.07 349.1 C 840.89 350.25 845.65 351.52 850.33 352.9 C 855.01 354.28 859.62 355.77 864.16 357.39 C 868.71 359 873.19 360.73 877.61 362.6 C 882.04 364.46 886.39 366.44 890.7 368.56 C 895.02 370.68 899.27 372.93 903.48 375.32 C 907.69 377.71 911.85 380.23 915.97 382.9 C 920.08 385.56 924.17 388.38 928.18 391.31 C 932.18 394.25 936.15 397.32 940.01 400.51 C 943.88 403.69 947.68 407 951.37 410.41 C 955.06 413.82 958.67 417.34 962.14 420.95 C 965.61 424.56 968.99 428.28 972.21 432.06 C 975.44 435.85 978.54 439.74 981.5 443.69 C 984.46 447.64 987.29 451.67 990 455.77 C 992.7 459.87 995.27 464.05 997.72 468.28 C 1000.16 472.51 1002.48 476.81 1004.67 481.17 C 1006.86 485.52 1008.93 489.93 1010.87 494.39 C 1012.81 498.85 1014.62 503.36 1016.32 507.92 C 1018.03 512.47 1019.6 517.07 1021.09 521.71 C 1022.57 526.35 1023.94 531.03 1025.22 535.75 C 1026.51 540.46 1027.69 545.22 1028.79 550.01 C 1029.9 554.79 1030.91 559.61 1031.86 564.46 C 1032.81 569.3 1033.67 574.18 1034.48 579.07 C 1035.3 583.97 1036.04 588.9 1036.73 593.84 C 1037.43 598.78 1038.07 603.74 1038.67 608.71 C 1039.27 613.69 1039.82 618.68 1040.35 623.68 C 1040.88 628.69 1041.37 633.7 1041.85 638.72 C 1042.33 643.74 1042.77 648.77 1043.22 653.8 C 1043.67 658.83 1044.09 663.86 1044.53 668.89 C 1044.96 673.92 1045.39 678.96 1045.83 683.98 C 1046.28 689 1046.72 694.03 1047.18 699.04 C 1047.64 704.06 1048.11 709.07 1048.59 714.07 C 1049.08 719.07 1049.57 724.07 1050.09 729.06 C 1050.61 734.05 1051.14 739.03 1051.69 744.01 C 1052.25 748.98 1052.82 753.94 1053.43 758.9 C 1054.03 763.85 1054.66 768.8 1055.32 773.73 C 1055.97 778.66 1056.66 783.58 1057.38 788.49 C 1058.1 793.4 1058.85 798.3 1059.64 803.19 C 1060.43 808.07 1061.25 812.94 1062.12 817.8 C 1062.98 822.65 1063.88 827.49 1064.84 832.32 C 1065.79 837.14 1066.78 841.95 1067.82 846.74 C 1068.86 851.54 1069.95 856.31 1071.09 861.07 C 1072.23 865.83 1073.42 870.57 1074.66 875.29 C 1075.9 880.01 1077.19 884.71 1078.53 889.39 C 1079.87 894.07 1081.26 898.74 1082.7 903.38 C 1084.14 908.03 1085.63 912.65 1087.17 917.25 C 1088.7 921.86 1090.29 926.44 1091.92 931.01 C 1093.55 935.57 1095.23 940.11 1096.95 944.64 C 1098.68 949.16 1100.45 953.66 1102.27 958.14 C 1104.09 962.62 1105.96 967.07 1107.87 971.51 C 1109.78 975.94 1111.74 980.36 1113.74 984.75 C 1115.74 989.14 1117.79 993.51 1119.88 997.85 C 1121.97 1002.2 1124.11 1006.52 1126.29 1010.82 C 1128.47 1015.12 1130.68 1019.39 1132.98 1023.64 C 1135.28 1027.9 1137.61 1032.14 1140.08 1036.37 C 1142.55 1040.6 1145.19 1044.81 1147.8 1049.05 C 1150.41 1053.29 1153.4 1057.48 1155.74 1061.81 C 1158.08 1066.15 1160.5 1070.5 1161.83 1075.07 C 1163.15 1079.64 1163.94 1084.48 1163.67 1089.24 C 1163.41 1094.01 1162.12 1099.19 1160.25 1103.65 C 1158.38 1108.12 1155.6 1112.62 1152.44 1116.03 C 1149.28 1119.44 1145.41 1122.17 1141.29 1124.11 C 1137.18 1126.04 1132.52 1126.99 1127.77 1127.66 C 1123.01 1128.32 1117.87 1128.23 1112.78 1128.1 C 1107.69 1127.97 1102.42 1127.41 1097.22 1126.89 C 1092.02 1126.37 1086.77 1125.64 1081.56 1124.97 C 1076.35 1124.31 1071.13 1123.53 1065.96 1122.91 C 1060.8 1122.28 1055.64 1121.64 1050.56 1121.24 C 1045.48 1120.84 1040.43 1120.5 1035.49 1120.51 C 1030.55 1120.51 1025.66 1120.67 1020.9 1121.26 C 1016.13 1121.85 1011.47 1122.74 1006.92 1124.05 C 1002.37 1125.35 997.95 1127.1 993.61 1129.07 C 989.26 1131.05 985.04 1133.41 980.85 1135.9 C 976.67 1138.38 972.58 1141.17 968.52 1143.99 C 964.45 1146.81 960.46 1149.85 956.46 1152.83 C 952.47 1155.82 948.52 1158.92 944.56 1161.9 C 940.59 1164.88 936.65 1167.86 932.67 1170.73 C 928.69 1173.59 924.71 1176.41 920.69 1179.1 C 916.66 1181.8 912.61 1184.42 908.5 1186.91 C 904.38 1189.39 900.24 1191.78 896 1194.01 C 891.77 1196.24 887.48 1198.36 883.09 1200.3 C 878.7 1202.24 874.22 1204.02 869.66 1205.65 C 865.1 1207.27 860.43 1208.73 855.72 1210.06 C 851 1211.38 846.2 1212.55 841.35 1213.6 C 836.5 1214.65 831.58 1215.56 826.64 1216.36 C 821.69 1217.17 816.69 1217.84 811.67 1218.42 C 806.65 1219.01 801.59 1219.47 796.52 1219.86 C 791.46 1220.25 786.37 1220.54 781.29 1220.75 C 776.21 1220.96 771.11 1221.08 766.03 1221.11 C 760.95 1221.13 755.86 1221.06 750.79 1220.88 C 745.73 1220.7 740.67 1220.43 735.64 1220.04 C 730.61 1219.65 725.6 1219.15 720.62 1218.53 C 715.64 1217.92 710.69 1217.19 705.78 1216.33 C 700.87 1215.47 696 1214.5 691.18 1213.38 C 686.36 1212.27 681.58 1211.03 676.87 1209.65 C 672.15 1208.27 667.49 1206.76 662.9 1205.1 C 658.3 1203.43 653.77 1201.63 649.32 1199.67 C 644.87 1197.71 640.48 1195.61 636.18 1193.34 C 631.89 1191.08 627.67 1188.65 623.55 1186.06 C 619.43 1183.48 615.42 1180.69 611.45 1177.81 C 607.49 1174.94 603.64 1171.88 599.76 1168.84 C 595.89 1165.8 592.08 1162.64 588.21 1159.59 C 584.33 1156.54 580.48 1153.44 576.51 1150.53 C 572.55 1147.62 568.56 1144.74 564.41 1142.12 C 560.27 1139.5 556.02 1137.02 551.64 1134.81 C 547.26 1132.6 542.73 1130.6 538.13 1128.87 C 533.53 1127.13 528.8 1125.62 524.03 1124.38 C 519.25 1123.14 514.38 1122.14 509.49 1121.42 C 504.6 1120.7 499.64 1120.23 494.69 1120.05 C 489.73 1119.87 484.73 1119.96 479.77 1120.35 C 474.8 1120.73 469.85 1121.51 464.88 1122.35 C 459.92 1123.19 454.99 1124.43 449.98 1125.4 C 444.97 1126.37 439.95 1127.51 434.81 1128.15 C 429.67 1128.79 424.35 1129.33 419.13 1129.23 C 413.91 1129.14 408.41 1128.69 403.49 1127.55 C 398.57 1126.42 393.65 1124.8 389.61 1122.4 C 385.57 1119.99 381.96 1116.81 379.27 1113.11 C 376.58 1109.4 374.66 1104.75 373.46 1100.17 C 372.26 1095.59 371.84 1090.4 372.09 1085.62 C 372.34 1080.84 373.46 1076.02 374.96 1071.49 C 376.46 1066.96 378.77 1062.71 381.07 1058.45 C 383.36 1054.19 386.16 1050.11 388.72 1045.94 C 391.27 1041.77 393.89 1037.62 396.37 1033.42 C 398.86 1029.22 401.27 1025 403.61 1020.75 C 405.96 1016.49 408.24 1012.22 410.45 1007.92 C 412.67 1003.62 414.82 999.29 416.91 994.94 C 419 990.59 421.03 986.21 423 981.81 C 424.97 977.41 426.87 972.99 428.73 968.54 C 430.58 964.1 432.38 959.63 434.12 955.13 C 435.87 950.64 437.56 946.13 439.2 941.59 C 440.84 937.05 442.42 932.49 443.96 927.91 C 445.5 923.33 446.99 918.73 448.44 914.11 C 449.88 909.48 451.28 904.84 452.64 900.17 C 454 895.51 455.31 890.82 456.58 886.12 C 457.85 881.41 459.08 876.69 460.28 871.94 C 461.47 867.2 462.62 862.44 463.73 857.66 C 464.84 852.88 465.91 848.08 466.95 843.27 C 467.98 838.46 468.98 833.63 469.94 828.78 C 470.9 823.93 471.82 819.07 472.71 814.2 C 473.6 809.32 474.45 804.43 475.27 799.53 C 476.09 794.62 476.88 789.7 477.63 784.77 C 478.39 779.84 479.1 774.9 479.79 769.94 C 480.48 764.99 481.14 760.02 481.77 755.05 C 482.4 750.07 482.99 745.08 483.56 740.08 C 484.13 735.09 484.67 730.08 485.18 725.06 C 485.69 720.05 486.17 715.02 486.63 709.99 C 487.09 704.96 487.52 699.92 487.95 694.88 C 488.38 689.84 488.79 684.79 489.2 679.75 C 489.62 674.71 490.02 669.66 490.44 664.63 C 490.86 659.59 491.28 654.55 491.74 649.52 C 492.19 644.5 492.65 639.48 493.15 634.47 C 493.65 629.46 494.16 624.46 494.73 619.48 C 495.3 614.5 495.9 609.53 496.56 604.58 C 497.23 599.63 497.93 594.7 498.7 589.79 C 499.47 584.88 500.29 579.99 501.2 575.13 C 502.11 570.27 503.07 565.43 504.13 560.62 C 505.19 555.81 506.32 551.03 507.55 546.29 C 508.79 541.54 510.1 536.82 511.53 532.15 C 512.96 527.47 514.48 522.82 516.11 518.23 C 517.75 513.63 519.48 509.07 521.32 504.56 C 523.17 500.05 525.11 495.58 527.16 491.18 C 529.21 486.78 531.37 482.42 533.63 478.13 C 535.89 473.84 538.25 469.61 540.73 465.45 C 543.2 461.29 545.77 457.19 548.46 453.18 C 551.14 449.16 553.93 445.21 556.83 441.35 C 559.73 437.48 562.73 433.69 565.84 430 C 568.95 426.3 572.17 422.68 575.5 419.17 C 578.82 415.65 582.26 412.22 585.8 408.9 C 589.34 405.57 592.99 402.34 596.75 399.22 C 600.5 396.1 604.37 393.08 608.32 390.18 C 612.28 387.28 616.34 384.49 620.47 381.81 C 624.6 379.14 628.82 376.58 633.1 374.15 C 637.38 371.72 641.75 369.41 646.16 367.23 C 650.57 365.06 655.05 363 659.57 361.09 C 664.09 359.18 668.66 357.4 673.28 355.76 C 677.89 354.12 682.55 352.62 687.25 351.24 C 691.95 349.87 696.7 348.64 701.49 347.53 C 706.27 346.43 711.1 345.46 715.97 344.62 C 720.84 343.78 725.75 343.08 730.69 342.5 C 735.63 341.93 740.62 341.49 745.63 341.18 Z M 762.89 671.4 C 759.65 671.75 756.31 672.62 753.17 673.82 C 750.02 675.03 746.87 676.72 744.03 678.64 C 741.18 680.57 738.44 682.89 736.1 685.37 C 733.77 687.85 731.69 690.64 730.01 693.53 C 728.32 696.42 726.99 699.54 725.99 702.71 C 724.99 705.88 724.34 709.22 724.01 712.55 C 723.68 715.89 723.69 719.35 724.02 722.73 C 724.35 726.11 725.02 729.56 725.99 732.84 C 726.96 736.11 728.26 739.38 729.87 742.38 C 731.47 745.37 733.4 748.26 735.62 750.8 C 737.84 753.33 740.42 755.65 743.18 757.58 C 745.94 759.51 749.03 761.15 752.16 762.38 C 755.28 763.61 758.64 764.5 761.92 764.96 C 765.21 765.41 768.61 765.47 771.85 765.1 C 775.09 764.73 778.32 763.89 781.36 762.72 C 784.4 761.55 787.37 759.94 790.09 758.07 C 792.81 756.2 795.4 753.95 797.68 751.49 C 799.96 749.02 802.05 746.22 803.79 743.3 C 805.54 740.37 807.03 737.17 808.15 733.93 C 809.27 730.7 810.1 727.27 810.51 723.89 C 810.93 720.51 811 717.03 810.65 713.67 C 810.3 710.31 809.52 706.94 808.43 703.75 C 807.34 700.55 805.84 697.41 804.1 694.51 C 802.37 691.6 800.28 688.81 798.02 686.32 C 795.75 683.82 793.19 681.5 790.51 679.54 C 787.83 677.58 784.91 675.86 781.93 674.56 C 778.94 673.25 775.78 672.24 772.61 671.72 C 769.43 671.19 766.13 671.05 762.89 671.4 Z M 671.71 546.9 C 668.66 547.07 665.52 547.73 662.53 548.74 C 659.55 549.74 656.55 551.2 653.81 552.91 C 651.07 554.63 648.4 556.73 646.09 559.03 C 643.77 561.32 641.67 563.94 639.92 566.68 C 638.17 569.43 636.71 572.43 635.59 575.49 C 634.46 578.55 633.64 581.8 633.16 585.04 C 632.68 588.29 632.51 591.67 632.69 594.97 C 632.86 598.27 633.38 601.64 634.21 604.85 C 635.04 608.06 636.2 611.27 637.65 614.23 C 639.1 617.19 640.86 620.06 642.89 622.6 C 644.92 625.14 647.28 627.49 649.81 629.47 C 652.35 631.45 655.2 633.16 658.11 634.47 C 661.02 635.79 664.15 636.8 667.26 637.39 C 670.37 637.97 673.62 638.19 676.75 637.98 C 679.89 637.78 683.07 637.13 686.08 636.14 C 689.08 635.16 692.06 633.76 694.79 632.08 C 697.52 630.39 700.14 628.34 702.45 626.06 C 704.76 623.78 706.88 621.15 708.65 618.38 C 710.42 615.61 711.92 612.55 713.07 609.45 C 714.22 606.34 715.08 603.03 715.55 599.76 C 716.01 596.49 716.14 593.1 715.88 589.82 C 715.62 586.54 714.94 583.24 713.98 580.1 C 713.01 576.96 711.65 573.87 710.07 570.99 C 708.49 568.11 706.58 565.33 704.49 562.83 C 702.4 560.33 700.04 557.99 697.55 555.99 C 695.06 553.99 692.34 552.2 689.56 550.82 C 686.77 549.43 683.82 548.32 680.84 547.67 C 677.87 547.01 674.76 546.72 671.71 546.9 Z M 856.41 547.73 C 853.3 548.06 850.15 548.88 847.19 550.04 C 844.23 551.21 841.3 552.84 838.62 554.72 C 835.95 556.61 833.39 558.89 831.14 561.35 C 828.9 563.81 826.86 566.61 825.16 569.5 C 823.47 572.4 822.04 575.55 820.97 578.71 C 819.9 581.88 819.13 585.23 818.75 588.51 C 818.37 591.79 818.34 595.16 818.7 598.39 C 819.06 601.63 819.84 604.86 820.92 607.92 C 821.99 610.97 823.46 613.97 825.15 616.73 C 826.84 619.49 828.86 622.13 831.05 624.5 C 833.24 626.86 835.71 629.04 838.29 630.89 C 840.86 632.74 843.66 634.36 846.52 635.59 C 849.37 636.82 852.39 637.77 855.41 638.27 C 858.42 638.77 861.55 638.91 864.61 638.6 C 867.67 638.29 870.8 637.52 873.75 636.42 C 876.7 635.32 879.65 633.79 882.32 632 C 885 630.21 887.58 628.05 889.81 625.68 C 892.05 623.32 894.06 620.63 895.73 617.82 C 897.4 615 898.79 611.93 899.84 608.81 C 900.89 605.7 901.64 602.4 902.03 599.13 C 902.42 595.87 902.47 592.5 902.17 589.23 C 901.87 585.97 901.19 582.68 900.21 579.55 C 899.24 576.43 897.91 573.34 896.31 570.49 C 894.72 567.64 892.8 564.89 890.65 562.43 C 888.5 559.98 886.04 557.7 883.43 555.77 C 880.82 553.85 877.93 552.16 875 550.88 C 872.07 549.59 868.93 548.61 865.83 548.08 C 862.73 547.56 859.51 547.4 856.41 547.73 Z"/></svg>Войти через GhostID</a></html>'
    return HTMLResponse(markup, headers=headers)
