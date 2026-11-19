"""Только веб, без бота."""
import uvicorn
import config
import db
from web.api import create_app

db.init()
app = create_app(None)

if __name__ == "__main__":
    uvicorn.run(app, host=config.WEB_HOST, port=config.WEB_PORT,
                proxy_headers=True, forwarded_allow_ips="*")
