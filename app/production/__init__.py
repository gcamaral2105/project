from flask import Blueprint


production_bp = Blueprint('production_bp', __name__,
                    template_folder='templates',
                    static_folder='static')


from app.production import routes