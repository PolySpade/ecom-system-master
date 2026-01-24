from flask import Flask, render_template, Response, request, jsonify, send_from_directory
import logging
import os
import atexit
from camera_handler import CameraHandler
from barcode_handler import BarcodeHandler
from database import Database
import config
from camera_utils import get_available_cameras

# Configure logging
os.makedirs(config.LOG_PATH, exist_ok=True)
logging.basicConfig(
    level=getattr(logging, config.LOG_LEVEL),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(config.LOG_FILE),
        logging.StreamHandler()
    ]
)

logger = logging.getLogger(__name__)

# Initialize Flask app
app = Flask(__name__)

# Initialize handlers
camera = CameraHandler()
barcode_handler = BarcodeHandler()
db = Database()

# Current transaction ID
current_transaction_id = None


@app.route('/')
def index():
    """Render the main UI."""
    return render_template('index.html')


@app.route('/video_feed')
def video_feed():
    """Video streaming route."""
    return Response(
        camera.generate_frames(),
        mimetype='multipart/x-mixed-replace; boundary=frame'
    )


@app.route('/api/status', methods=['GET'])
def get_status():
    """Get the current recording status."""
    try:
        status = {
            'recording': camera.is_recording(),
            'duration': camera.get_recording_duration(),
            'filename': camera.current_filename,
            'storage_used_mb': db.get_total_storage_used()
        }
        return jsonify(status), 200
    except Exception as e:
        logger.error(f"Error getting status: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/barcode', methods=['POST'])
def process_barcode():
    """Process a barcode input."""
    global current_transaction_id

    try:
        data = request.get_json()
        barcode_input = data.get('barcode', '').strip()

        if not barcode_input:
            return jsonify({'error': 'Barcode is required'}), 400

        # Process barcode with current recording state
        result = barcode_handler.process_barcode(barcode_input, camera.is_recording())

        if result['action'] == 'invalid':
            return jsonify({'error': 'Invalid barcode'}), 400

        if result['action'] == 'start':
            # Start recording
            filename = camera.start_recording(result['barcode'])

            # Create database transaction
            current_transaction_id = db.create_transaction(result['barcode'], filename)

            return jsonify({
                'action': 'started',
                'barcode': result['barcode'],
                'filename': filename,
                'transaction_id': current_transaction_id
            }), 200

        elif result['action'] == 'stop_and_start':
            # Stop current recording
            recording_info = camera.stop_recording()

            # Update database transaction for completed recording
            if current_transaction_id:
                db.complete_transaction(
                    current_transaction_id,
                    recording_info['duration'],
                    recording_info['file_size_mb'],
                    'barcode'
                )

            # Immediately start new recording with this barcode
            new_filename = camera.start_recording(result['barcode'])

            # Create new database transaction
            current_transaction_id = db.create_transaction(result['barcode'], new_filename)

            response = {
                'action': 'stop_and_start',
                'barcode': result['barcode'],
                'previous_filename': recording_info['filename'],
                'previous_duration': recording_info['duration'],
                'previous_file_size_mb': recording_info['file_size_mb'],
                'new_filename': new_filename,
                'transaction_id': current_transaction_id
            }

            return jsonify(response), 200

        elif result['action'] == 'stop':
            # Stop recording
            recording_info = camera.stop_recording()

            # Update database transaction
            if current_transaction_id:
                db.complete_transaction(
                    current_transaction_id,
                    recording_info['duration'],
                    recording_info['file_size_mb'],
                    'barcode'
                )

            response = {
                'action': 'stopped',
                'filename': recording_info['filename'],
                'duration': recording_info['duration'],
                'file_size_mb': recording_info['file_size_mb'],
                'stop_method': 'barcode'
            }

            current_transaction_id = None
            return jsonify(response), 200

    except Exception as e:
        logger.error(f"Error processing barcode: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/stop', methods=['POST'])
def manual_stop():
    """Manually stop recording."""
    global current_transaction_id

    try:
        if not camera.is_recording():
            return jsonify({'error': 'Not currently recording'}), 400

        # Stop recording
        recording_info = camera.stop_recording()

        # Update database transaction
        if current_transaction_id:
            db.complete_transaction(
                current_transaction_id,
                recording_info['duration'],
                recording_info['file_size_mb'],
                'manual'
            )

        response = {
            'action': 'stopped',
            'filename': recording_info['filename'],
            'duration': recording_info['duration'],
            'file_size_mb': recording_info['file_size_mb'],
            'stop_method': 'manual'
        }

        current_transaction_id = None
        return jsonify(response), 200

    except Exception as e:
        logger.error(f"Error stopping recording: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/recordings', methods=['GET'])
def get_recordings():
    """Get recent recordings."""
    try:
        limit = request.args.get('limit', 10, type=int)
        recordings = db.get_recent_transactions(limit)
        return jsonify(recordings), 200
    except Exception as e:
        logger.error(f"Error fetching recordings: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/search', methods=['GET'])
def search_recordings():
    """Search for recordings by barcode."""
    try:
        barcode = request.args.get('barcode', '').strip()

        if not barcode:
            return jsonify({'error': 'Barcode parameter is required'}), 400

        results = db.search_by_barcode(barcode)
        return jsonify(results), 200
    except Exception as e:
        logger.error(f"Error searching recordings: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/search/advanced', methods=['GET'])
def advanced_search_recordings():
    """Advanced search with filtering, sorting, and pagination."""
    try:
        barcode = request.args.get('barcode', '').strip() or None
        start_date = request.args.get('start_date', '').strip() or None
        end_date = request.args.get('end_date', '').strip() or None
        sort_by = request.args.get('sort_by', 'created_at')
        sort_order = request.args.get('sort_order', 'DESC')
        limit = request.args.get('limit', type=int) or 20
        offset = request.args.get('offset', type=int) or 0

        results = db.advanced_search(
            barcode=barcode,
            start_date=start_date,
            end_date=end_date,
            sort_by=sort_by,
            sort_order=sort_order,
            limit=limit,
            offset=offset
        )

        return jsonify(results), 200
    except Exception as e:
        logger.error(f"Error in advanced search: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/videos/<date_folder>/<filename>')
def serve_video(date_folder, filename):
    """Serve video files."""
    try:
        video_dir = os.path.join(config.VIDEO_STORAGE_PATH, date_folder)
        return send_from_directory(video_dir, filename, as_attachment=False)
    except Exception as e:
        logger.error(f"Error serving video: {e}")
        return jsonify({'error': 'Video not found'}), 404


@app.route('/videos/<date_folder>/<filename>/download')
def download_video(date_folder, filename):
    """Download video files."""
    try:
        video_dir = os.path.join(config.VIDEO_STORAGE_PATH, date_folder)
        return send_from_directory(video_dir, filename, as_attachment=True)
    except Exception as e:
        logger.error(f"Error downloading video: {e}")
        return jsonify({'error': 'Video not found'}), 404


@app.route('/api/settings', methods=['GET'])
def get_settings():
    """Get current settings."""
    try:
        settings = config.settings_manager.get_all()
        return jsonify(settings), 200
    except Exception as e:
        logger.error(f"Error getting settings: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/settings', methods=['POST'])
def save_settings():
    """Save settings."""
    try:
        data = request.get_json()

        if not data:
            return jsonify({'error': 'No settings data provided'}), 400

        # Update each category
        for category, values in data.items():
            if isinstance(values, dict):
                config.settings_manager.update_category(category, values)

        # Save to file
        if config.settings_manager.save_settings():
            return jsonify({'success': True, 'message': 'Settings saved successfully'}), 200
        else:
            return jsonify({'error': 'Failed to save settings'}), 500

    except Exception as e:
        logger.error(f"Error saving settings: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/settings/reset', methods=['POST'])
def reset_settings():
    """Reset settings to defaults."""
    try:
        config.settings_manager.reset_to_defaults()
        if config.settings_manager.save_settings():
            return jsonify({'success': True, 'message': 'Settings reset to defaults'}), 200
        else:
            return jsonify({'error': 'Failed to reset settings'}), 500
    except Exception as e:
        logger.error(f"Error resetting settings: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/cameras', methods=['GET'])
def get_cameras():
    """Get list of available cameras."""
    try:
        cameras = get_available_cameras()
        return jsonify(cameras), 200
    except Exception as e:
        logger.error(f"Error getting cameras: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/camera/restart', methods=['POST'])
def restart_camera():
    """Restart the camera with new settings."""
    global camera

    try:
        if camera.is_recording():
            return jsonify({'error': 'Cannot restart camera while recording'}), 400

        camera.reinitialize()
        return jsonify({'success': True, 'message': 'Camera restarted successfully'}), 200
    except Exception as e:
        logger.error(f"Error restarting camera: {e}")
        return jsonify({'error': str(e)}), 500


def cleanup():
    """Clean up resources on shutdown."""
    logger.info("Shutting down application...")
    camera.cleanup()


# Register cleanup function
atexit.register(cleanup)


if __name__ == '__main__':
    logger.info("Starting Ecom Video Tracker")
    logger.info(f"Server running on http://{config.FLASK_HOST}:{config.FLASK_PORT}")

    try:
        app.run(
            host=config.FLASK_HOST,
            port=config.FLASK_PORT,
            debug=config.DEBUG_MODE,
            threaded=True
        )
    except KeyboardInterrupt:
        logger.info("Received keyboard interrupt")
    finally:
        cleanup()
