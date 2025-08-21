"""
Mine Routes
===========

Flask routes for mine management API endpoints with special support
for creating mines with associated products in a single operation.
"""

from flask import Blueprint, request, jsonify
from typing import Dict, Any, Tuple

from app.mine.services.mine_service import MineService


# Create Blueprint
mine_bp = Blueprint('mines', __name__, url_prefix='/api/mines')

# Initialize service (will be created per request)
def get_mine_service() -> MineService:
    """Factory function to create MineService instance."""
    return MineService()


# ─────────────────────────── helper functions ──────────────────────────── #

def get_request_json() -> Dict[str, Any]:
    """Get JSON data from request with error handling."""
    if not request.is_json:
        return {}
    return request.get_json() or {}


def get_pagination_params() -> Tuple[int, int]:
    """Extract pagination parameters from request."""
    page = request.args.get('page', 1, type=int)
    per_page = request.args.get('per_page', 20, type=int)
    
    # Validate pagination parameters
    page = max(1, page)
    per_page = max(1, min(100, per_page))  # Limit max per_page to 100
    
    return page, per_page


def get_filter_params() -> Dict[str, Any]:
    """Extract filter parameters from request."""
    return {
        'country': request.args.get('country', type=str),
        'search_query': request.args.get('q', type=str),
        'include_deleted': request.args.get('include_deleted', 'false').lower() == 'true',
        'sort_by': request.args.get('sort_by', 'id', type=str),
        'sort_direction': request.args.get('sort_direction', 'asc', type=str),
        'include_products': request.args.get('include_products', 'false').lower() == 'true',
    }


def create_error_response(message: str, status_code: int = 400, errors: list = None) -> Tuple[Dict[str, Any], int]:
    """Create standardized error response."""
    return {
        'success': False,
        'message': message,
        'errors': errors or [],
        'data': None
    }, status_code


def create_success_response(data: Any, message: str = "Success", metadata: Dict[str, Any] = None) -> Dict[str, Any]:
    """Create standardized success response."""
    response = {
        'success': True,
        'message': message,
        'data': data,
        'errors': []
    }
    if metadata:
        response['metadata'] = metadata
    return response


# ─────────────────────────── route handlers ─────────────────────────────── #

@mine_bp.route('', methods=['GET'])
def list_mines():
    """
    List mines with filtering and pagination.
    
    Query Parameters:
        - page (int): Page number (default: 1)
        - per_page (int): Items per page (default: 20, max: 100)
        - country (str): Filter by country
        - q (str): Search query for name/code/country
        - include_deleted (bool): Include soft-deleted mines
        - sort_by (str): Sort field (id, name, country, created_at, updated_at)
        - sort_direction (str): Sort direction (asc, desc)
        - include_products (bool): Include products data in response
    
    Returns:
        JSON response with paginated mine list
    """
    try:
        service = get_mine_service()
        page, per_page = get_pagination_params()
        filters = get_filter_params()
        
        result = service.list_mines(
            page=page,
            per_page=per_page,
            **filters
        )
        
        if not result.get('success'):
            return jsonify(result), 400
            
        return jsonify(result)
        
    except Exception as e:
        return jsonify(create_error_response(f"Failed to list mines: {str(e)}", 500))


@mine_bp.route('/<int:mine_id>', methods=['GET'])
def get_mine(mine_id: int):
    """
    Get a specific mine by ID.
    
    Path Parameters:
        - mine_id (int): Mine ID
        
    Query Parameters:
        - include_products (bool): Include products data in response
    
    Returns:
        JSON response with mine data
    """
    try:
        service = get_mine_service()
        include_products = request.args.get('include_products', 'false').lower() == 'true'
        
        result = service.get_mine(mine_id, include_products=include_products)
        
        if not result.get('success'):
            status_code = 404 if 'not found' in result.get('message', '').lower() else 400
            return jsonify(result), status_code
            
        return jsonify(result)
        
    except Exception as e:
        return jsonify(create_error_response(f"Failed to get mine: {str(e)}", 500))


@mine_bp.route('', methods=['POST'])
def create_mine():
    """
    Create a new mine.
    
    Request Body:
        JSON object with mine data:
        - name (str, required): Mine name
        - country (str, required): Country
        - port_location (str, required): Port location
        - port_latitude (float, required): Port latitude (-90 to 90)
        - port_longitude (float, required): Port longitude (-180 to 180)
        - code (str, optional): Mine code
        - port_berths (int, optional): Number of port berths
        - shiploaders (int, optional): Number of shiploaders
    
    Returns:
        JSON response with created mine data
    """
    try:
        service = get_mine_service()
        data = get_request_json()
        
        if not data:
            return jsonify(create_error_response("Request body must be valid JSON", 400))
        
        result = service.create_mine(data)
        
        if not result.get('success'):
            return jsonify(result), 400
            
        return jsonify(result), 201
        
    except Exception as e:
        return jsonify(create_error_response(f"Failed to create mine: {str(e)}", 500))


@mine_bp.route('/with-products', methods=['POST'])
def create_mine_with_products():
    """
    Create a mine with associated products in a single transaction.
    
    Request Body:
        JSON object with:
        - mine (object, required): Mine data
          - name (str, required): Mine name
          - country (str, required): Country
          - port_location (str, required): Port location
          - port_latitude (float, required): Port latitude (-90 to 90)
          - port_longitude (float, required): Port longitude (-180 to 180)
          - code (str, optional): Mine code
          - port_berths (int, optional): Number of port berths
          - shiploaders (int, optional): Number of shiploaders
        - products (array, required): List of product data
          - name (str, required): Product name
          - code (str, optional): Product code
          - description (str, optional): Product description
    
    Returns:
        JSON response with created mine and products data
    """
    try:
        service = get_mine_service()
        data = get_request_json()
        
        if not data:
            return jsonify(create_error_response("Request body must be valid JSON", 400))
        
        # Validate request structure
        if 'mine' not in data:
            return jsonify(create_error_response("'mine' data is required", 400))
        
        if 'products' not in data:
            return jsonify(create_error_response("'products' data is required", 400))
        
        if not isinstance(data['products'], list):
            return jsonify(create_error_response("'products' must be an array", 400))
        
        if not data['products']:
            return jsonify(create_error_response("At least one product is required", 400))
        
        mine_data = data['mine']
        products_data = data['products']
        
        result = service.create_mine_with_products(mine_data, products_data)
        
        if not result.get('success'):
            return jsonify(result), 400
            
        return jsonify(result), 201
        
    except Exception as e:
        return jsonify(create_error_response(f"Failed to create mine with products: {str(e)}", 500))


@mine_bp.route('/<int:mine_id>', methods=['PUT'])
def update_mine(mine_id: int):
    """
    Update an existing mine.
    
    Path Parameters:
        - mine_id (int): Mine ID
        
    Request Body:
        JSON object with updated mine data:
        - name (str, optional): Mine name
        - code (str, optional): Mine code
        - country (str, optional): Country
        - port_location (str, optional): Port location
        - port_latitude (float, optional): Port latitude
        - port_longitude (float, optional): Port longitude
        - port_berths (int, optional): Number of port berths
        - shiploaders (int, optional): Number of shiploaders
    
    Returns:
        JSON response with updated mine data
    """
    try:
        service = get_mine_service()
        data = get_request_json()
        
        if not data:
            return jsonify(create_error_response("Request body must be valid JSON", 400))
        
        result = service.update_mine(mine_id, data)
        
        if not result.get('success'):
            status_code = 404 if 'not found' in result.get('message', '').lower() else 400
            return jsonify(result), status_code
            
        return jsonify(result)
        
    except Exception as e:
        return jsonify(create_error_response(f"Failed to update mine: {str(e)}", 500))


@mine_bp.route('/<int:mine_id>', methods=['DELETE'])
def delete_mine(mine_id: int):
    """
    Delete a mine (soft delete by default).
    
    Path Parameters:
        - mine_id (int): Mine ID
        
    Query Parameters:
        - permanent (bool): Perform permanent delete instead of soft delete
    
    Returns:
        JSON response confirming deletion
    """
    try:
        service = get_mine_service()
        permanent = request.args.get('permanent', 'false').lower() == 'true'
        soft_delete = not permanent
        
        result = service.delete_mine(mine_id, soft_delete=soft_delete)
        
        if not result.get('success'):
            status_code = 404 if 'not found' in result.get('message', '').lower() else 400
            return jsonify(result), status_code
            
        return jsonify(result)
        
    except Exception as e:
        return jsonify(create_error_response(f"Failed to delete mine: {str(e)}", 500))


@mine_bp.route('/<int:mine_id>/restore', methods=['POST'])
def restore_mine(mine_id: int):
    """
    Restore a soft-deleted mine.
    
    Path Parameters:
        - mine_id (int): Mine ID
    
    Returns:
        JSON response confirming restoration
    """
    try:
        service = get_mine_service()
        
        result = service.restore_mine(mine_id)
        
        if not result.get('success'):
            status_code = 404 if 'not found' in result.get('message', '').lower() else 400
            return jsonify(result), status_code
            
        return jsonify(result)
        
    except Exception as e:
        return jsonify(create_error_response(f"Failed to restore mine: {str(e)}", 500))


@mine_bp.route('/search', methods=['GET'])
def search_mines():
    """
    Search mines by name, code, or country.
    
    Query Parameters:
        - q (str, required): Search query
        - limit (int, optional): Maximum results (default: 10, max: 50)
    
    Returns:
        JSON response with search results
    """
    try:
        service = get_mine_service()
        query = request.args.get('q', '').strip()
        
        if not query:
            return jsonify(create_error_response("Search query 'q' is required", 400))
        
        limit = min(50, max(1, request.args.get('limit', 10, type=int)))
        
        result = service.search_mines(query, limit=limit)
        
        if not result.get('success'):
            return jsonify(result), 400
            
        return jsonify(result)
        
    except Exception as e:
        return jsonify(create_error_response(f"Failed to search mines: {str(e)}", 500))


@mine_bp.route('/country/<country>', methods=['GET'])
def get_mines_by_country(country: str):
    """
    Get all mines for a specific country.
    
    Path Parameters:
        - country (str): Country name
        
    Query Parameters:
        - include_deleted (bool): Include soft-deleted mines
    
    Returns:
        JSON response with country's mines
    """
    try:
        service = get_mine_service()
        include_deleted = request.args.get('include_deleted', 'false').lower() == 'true'
        
        result = service.get_mines_by_country(country, include_deleted=include_deleted)
        
        if not result.get('success'):
            return jsonify(result), 400
            
        return jsonify(result)
        
    except Exception as e:
        return jsonify(create_error_response(f"Failed to get mines by country: {str(e)}", 500))


@mine_bp.route('/statistics', methods=['GET'])
def get_mine_statistics():
    """
    Get mine statistics.
    
    Returns:
        JSON response with mine statistics
    """
    try:
        service = get_mine_service()
        
        result = service.get_mine_statistics()
        
        if not result.get('success'):
            return jsonify(result), 400
            
        return jsonify(result)
        
    except Exception as e:
        return jsonify(create_error_response(f"Failed to get statistics: {str(e)}", 500))


# ─────────────────────────── error handlers ─────────────────────────────── #

@mine_bp.errorhandler(404)
def not_found(error):
    """Handle 404 errors."""
    return jsonify(create_error_response("Resource not found", 404))


@mine_bp.errorhandler(405)
def method_not_allowed(error):
    """Handle 405 errors."""
    return jsonify(create_error_response("Method not allowed", 405))


@mine_bp.errorhandler(500)
def internal_error(error):
    """Handle 500 errors."""
    return jsonify(create_error_response("Internal server error", 500))


# ─────────────────────────── health check ──────────────────────────────── #

@mine_bp.route('/health', methods=['GET'])
def health_check():
    """
    Health check endpoint.
    
    Returns:
        JSON response indicating service health
    """
    try:
        service = get_mine_service()
        metrics = service.get_metrics()
        
        return jsonify({
            'success': True,
            'message': 'Mine service is healthy',
            'data': {
                'service': 'mine',
                'status': 'healthy',
                'metrics': metrics
            }
        })
        
    except Exception as e:
        return jsonify(create_error_response(f"Service unhealthy: {str(e)}", 503))

