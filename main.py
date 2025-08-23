import os
from dotenv import load_dotenv
from app import create_app

# Load variables from .env
load_dotenv()

# Creates application from factory
app = create_app()

if __name__=='__main__':
    # Port and optional host
    port = int(os.environ.get('PORT', 5000))
    app.run(host='0.0.0.0', port=port, debug=app.config.get('DEBUG', True))
