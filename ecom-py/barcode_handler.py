import logging
import config

logger = logging.getLogger(__name__)


class BarcodeHandler:
    def __init__(self):
        self.last_barcode = None

    def validate_barcode(self, barcode: str) -> bool:
        """
        Validate barcode input.

        Args:
            barcode: The barcode string to validate

        Returns:
            True if valid, False otherwise
        """
        if not barcode or not isinstance(barcode, str):
            return False

        # Remove whitespace
        barcode = barcode.strip()

        # Check minimum length
        if len(barcode) < 1:
            return False

        return True

    def is_start_code(self, barcode: str) -> bool:
        """
        Check if barcode is a start code.

        Args:
            barcode: The barcode to check

        Returns:
            True if it's a start code
        """
        return barcode.startswith(config.BARCODE_START_PREFIX)

    def is_stop_code(self, barcode: str) -> bool:
        """
        Check if barcode is a stop code.

        Args:
            barcode: The barcode to check

        Returns:
            True if it's a stop code
        """
        return barcode.startswith(config.BARCODE_STOP_PREFIX)

    def process_barcode(self, barcode: str, is_recording: bool = False) -> dict:
        """
        Process a barcode input and determine action.

        Args:
            barcode: The barcode string
            is_recording: Whether a recording is currently in progress

        Returns:
            Dictionary with 'action' ('start', 'stop_and_start') and 'barcode'
            - 'start': Start new recording (when not recording)
            - 'stop_and_start': Stop current recording and immediately start new one
        """
        if not self.validate_barcode(barcode):
            logger.warning(f"Invalid barcode: {barcode}")
            return {'action': 'invalid', 'barcode': barcode}

        barcode = barcode.strip().upper()

        # If currently recording, stop current and start new recording with this barcode
        if is_recording:
            logger.info(f"Recording in progress - will stop current and start new recording: {barcode}")
            self.last_barcode = barcode
            return {'action': 'stop_and_start', 'barcode': barcode}

        # If not recording, start recording with this barcode
        logger.info(f"Barcode detected - starting recording: {barcode}")
        self.last_barcode = barcode
        return {'action': 'start', 'barcode': barcode}

    def get_last_barcode(self) -> str:
        """Get the last processed barcode."""
        return self.last_barcode
