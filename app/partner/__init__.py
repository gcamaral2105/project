from flask import Blueprint


partner_bp = Blueprint('partner_bp', __name__,
                    template_folder='templates',
                    static_folder='static')


from app.partner import routes