from flask import Blueprint


mine_bp = Blueprint('mine_bp', __name__,
                    template_folder='templates',
                    static_folder='static')


from app.product import routes
