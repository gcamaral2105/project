from flask import Flask
from .extensions import db, migrate

def create_app(config_class='config.Config'):
    app = Flask(__name__)
    app.config.from_object(config_class)

    db.init_app(app)
    migrate.init_app(app, db)

    with app.app_context():
        from app.product.routes.product_routes import product_bp

        app.register_blueprint(product_bp, url_prefix="/")
        
    return app

