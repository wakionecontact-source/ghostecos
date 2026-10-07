# Удаляет const с конструкторов которые ссылаются на GE.<dynamic_color>.
# Работает аккуратно с UTF-8 (без порчи кириллицы как PowerShell делает).
import re, sys, io

DYN = ('bg|bgDeep|surface|border|borderStrong|primary|primary2|text|sub|muted|'
       'green|yellow|red|blue|glassFill|glassBorder|glowFill|currentBrightness')
# (?s) — DOTALL: . матчит \n. Ищем простые конструкторы без вложенных скобок
PAT = re.compile(
    r'const\s+(\w+)\s*\(((?:[^()]|\([^()]*\))*?\bGE\.(?:' + DYN + r')\b(?:[^()]|\([^()]*\))*?)\)',
    re.DOTALL
)

files = [
    'app/desktop_wrapper/lib/main.dart',
    'app/desktop_wrapper/lib/mesh_background.dart',
    'app/desktop_wrapper/lib/screens/auth_screen.dart',
    'app/desktop_wrapper/lib/screens/main_shell.dart',
    'app/desktop_wrapper/lib/screens/welcome_screen.dart',
    'app/desktop_wrapper/lib/widgets/glass.dart',
]

base = r'C:\Users\Home\GE'

for f in files:
    path = f'{base}\\{f.replace("/", chr(92))}'
    with open(path, 'r', encoding='utf-8') as fp:
        src = fp.read()
    orig = src
    # Применяем 5 раз чтобы вложенные const тоже сняло
    for _ in range(5):
        new = PAT.sub(lambda m: m.group(1) + '(' + m.group(2) + ')', src)
        if new == src:
            break
        src = new
    if src != orig:
        with open(path, 'w', encoding='utf-8', newline='\n') as fp:
            fp.write(src)
        print(f'PATCHED: {f}')
    else:
        print(f'no-op:   {f}')
