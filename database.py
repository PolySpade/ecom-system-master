import sqlite3
import logging
from datetime import datetime
from typing import List, Dict, Optional
import config

logger = logging.getLogger(__name__)


class Database:
    def __init__(self, db_path: str = config.DATABASE_PATH):
        self.db_path = db_path
        self.init_database()

    def get_connection(self):
        """Get a database connection."""
        return sqlite3.connect(self.db_path)

    def init_database(self):
        """Initialize the database schema."""
        try:
            conn = self.get_connection()
            cursor = conn.cursor()

            # Create transactions table
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS transactions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    barcode TEXT NOT NULL,
                    video_filename TEXT NOT NULL,
                    start_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    end_time TIMESTAMP,
                    duration_seconds INTEGER,
                    file_size_mb REAL,
                    stop_method TEXT,
                    label TEXT DEFAULT 'Normal (Standard)',
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            ''')

            # Add label column if it doesn't exist (for existing databases)
            try:
                cursor.execute('ALTER TABLE transactions ADD COLUMN label TEXT DEFAULT "Normal (Standard)"')
                logger.info("Added label column to existing database")
            except sqlite3.OperationalError:
                # Column already exists
                pass

            # Add compression-related columns if they don't exist
            compression_columns = [
                ('compression_status', 'TEXT DEFAULT "pending"'),
                ('compressed_file_size_mb', 'REAL'),
                ('compression_ratio', 'REAL'),
                ('compressed_filename', 'TEXT')
            ]

            for column_name, column_def in compression_columns:
                try:
                    cursor.execute(f'ALTER TABLE transactions ADD COLUMN {column_name} {column_def}')
                    logger.info(f"Added {column_name} column to existing database")
                except sqlite3.OperationalError:
                    # Column already exists
                    pass

            conn.commit()
            conn.close()
            logger.info("Database initialized successfully")
        except Exception as e:
            logger.error(f"Error initializing database: {e}")
            raise

    def create_transaction(self, barcode: str, video_filename: str, label: str = "Normal (Standard)") -> int:
        """
        Create a new transaction record.

        Args:
            barcode: The barcode that triggered the recording
            video_filename: The filename of the video being recorded
            label: The video label/category

        Returns:
            The ID of the newly created transaction
        """
        try:
            conn = self.get_connection()
            cursor = conn.cursor()

            cursor.execute('''
                INSERT INTO transactions (barcode, video_filename, start_time, label)
                VALUES (?, ?, ?, ?)
            ''', (barcode, video_filename, datetime.now(), label))

            transaction_id = cursor.lastrowid
            conn.commit()
            conn.close()

            logger.info(f"Created transaction {transaction_id} for barcode {barcode} (Label: {label})")
            return transaction_id
        except Exception as e:
            logger.error(f"Error creating transaction: {e}")
            raise

    def complete_transaction(
        self,
        transaction_id: int,
        duration_seconds: int,
        file_size_mb: float,
        stop_method: str
    ):
        """
        Complete a transaction record with final details.

        Args:
            transaction_id: The ID of the transaction to complete
            duration_seconds: Duration of the recording in seconds
            file_size_mb: Size of the video file in MB
            stop_method: How the recording was stopped ('manual' or 'barcode')
        """
        try:
            conn = self.get_connection()
            cursor = conn.cursor()

            cursor.execute('''
                UPDATE transactions
                SET end_time = ?,
                    duration_seconds = ?,
                    file_size_mb = ?,
                    stop_method = ?
                WHERE id = ?
            ''', (datetime.now(), duration_seconds, file_size_mb, stop_method, transaction_id))

            conn.commit()
            conn.close()

            logger.info(f"Completed transaction {transaction_id}")
        except Exception as e:
            logger.error(f"Error completing transaction: {e}")
            raise

    def get_recent_transactions(self, limit: int = 10) -> List[Dict]:
        """
        Get the most recent transactions.

        Args:
            limit: Maximum number of transactions to return

        Returns:
            List of transaction dictionaries
        """
        try:
            conn = self.get_connection()
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()

            cursor.execute('''
                SELECT * FROM transactions
                ORDER BY created_at DESC
                LIMIT ?
            ''', (limit,))

            rows = cursor.fetchall()
            transactions = [dict(row) for row in rows]

            conn.close()
            return transactions
        except Exception as e:
            logger.error(f"Error fetching recent transactions: {e}")
            return []

    def get_transaction(self, transaction_id: int) -> Optional[Dict]:
        """
        Get a specific transaction by ID.

        Args:
            transaction_id: The ID of the transaction

        Returns:
            Transaction dictionary or None if not found
        """
        try:
            conn = self.get_connection()
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()

            cursor.execute('SELECT * FROM transactions WHERE id = ?', (transaction_id,))
            row = cursor.fetchone()

            conn.close()
            return dict(row) if row else None
        except Exception as e:
            logger.error(f"Error fetching transaction: {e}")
            return None

    def get_total_storage_used(self) -> float:
        """
        Get the total storage used by all videos in MB.

        Returns:
            Total storage in MB
        """
        try:
            conn = self.get_connection()
            cursor = conn.cursor()

            cursor.execute('SELECT SUM(file_size_mb) FROM transactions WHERE file_size_mb IS NOT NULL')
            result = cursor.fetchone()[0]

            conn.close()
            return result if result else 0.0
        except Exception as e:
            logger.error(f"Error calculating total storage: {e}")
            return 0.0

    def search_by_barcode(self, barcode: str) -> List[Dict]:
        """
        Search for transactions by barcode (partial match supported).

        Args:
            barcode: The barcode to search for (case-insensitive, supports partial matches)

        Returns:
            List of matching transaction dictionaries
        """
        try:
            conn = self.get_connection()
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()

            # Use LIKE for partial matching, case-insensitive
            search_pattern = f"%{barcode}%"
            cursor.execute('''
                SELECT * FROM transactions
                WHERE UPPER(barcode) LIKE UPPER(?)
                ORDER BY created_at DESC
            ''', (search_pattern,))

            rows = cursor.fetchall()
            transactions = [dict(row) for row in rows]

            conn.close()
            logger.info(f"Found {len(transactions)} transactions matching '{barcode}'")
            return transactions
        except Exception as e:
            logger.error(f"Error searching for barcode '{barcode}': {e}")
            return []

    def advanced_search(
        self,
        barcode: Optional[str] = None,
        start_date: Optional[str] = None,
        end_date: Optional[str] = None,
        label: Optional[str] = None,
        sort_by: str = 'created_at',
        sort_order: str = 'DESC',
        limit: Optional[int] = None,
        offset: int = 0
    ) -> Dict:
        """
        Advanced search for transactions with filtering, sorting, and pagination.

        Args:
            barcode: Optional barcode to search for (case-insensitive, supports partial matches)
            start_date: Optional start date filter (ISO format: YYYY-MM-DD)
            end_date: Optional end date filter (ISO format: YYYY-MM-DD)
            label: Optional label/category filter (exact match)
            sort_by: Column to sort by (default: 'created_at')
            sort_order: Sort order - 'ASC' or 'DESC' (default: 'DESC')
            limit: Maximum number of results to return
            offset: Number of results to skip (for pagination)

        Returns:
            Dictionary with 'results' (list of transactions) and 'total' (total count)
        """
        try:
            conn = self.get_connection()
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()

            # Build query
            where_clauses = []
            params = []

            if barcode:
                where_clauses.append('UPPER(barcode) LIKE UPPER(?)')
                params.append(f'%{barcode}%')

            if start_date:
                where_clauses.append('DATE(created_at) >= ?')
                params.append(start_date)

            if end_date:
                where_clauses.append('DATE(created_at) <= ?')
                params.append(end_date)

            if label:
                where_clauses.append('label = ?')
                params.append(label)

            where_clause = f"WHERE {' AND '.join(where_clauses)}" if where_clauses else ''

            # Validate sort column
            valid_sort_columns = ['id', 'barcode', 'created_at', 'duration_seconds', 'file_size_mb', 'label']
            if sort_by not in valid_sort_columns:
                sort_by = 'created_at'

            # Validate sort order
            sort_order = 'DESC' if sort_order.upper() == 'DESC' else 'ASC'

            # Get total count
            count_query = f'SELECT COUNT(*) FROM transactions {where_clause}'
            cursor.execute(count_query, params)
            total = cursor.fetchone()[0]

            # Get results
            query = f'''
                SELECT * FROM transactions
                {where_clause}
                ORDER BY {sort_by} {sort_order}
            '''

            if limit is not None:
                query += f' LIMIT {limit} OFFSET {offset}'

            cursor.execute(query, params)
            rows = cursor.fetchall()
            results = [dict(row) for row in rows]

            conn.close()

            logger.info(f"Advanced search returned {len(results)} of {total} total results")
            return {
                'results': results,
                'total': total,
                'limit': limit,
                'offset': offset
            }

        except Exception as e:
            logger.error(f"Error in advanced search: {e}")
            return {'results': [], 'total': 0, 'limit': limit, 'offset': offset}

    def update_compression_status(
        self,
        transaction_id: int,
        status: str,
        compressed_file_size_mb: Optional[float] = None,
        compression_ratio: Optional[float] = None,
        compressed_filename: Optional[str] = None
    ):
        """
        Update the compression status for a transaction.

        Args:
            transaction_id: The ID of the transaction
            status: Compression status (pending/processing/completed/failed/skipped)
            compressed_file_size_mb: Size of compressed file in MB
            compression_ratio: Percentage of size reduction
            compressed_filename: Name of the compressed file
        """
        try:
            conn = self.get_connection()
            cursor = conn.cursor()

            # Build update query dynamically
            update_fields = ['compression_status = ?']
            params = [status]

            if compressed_file_size_mb is not None:
                update_fields.append('compressed_file_size_mb = ?')
                params.append(compressed_file_size_mb)

            if compression_ratio is not None:
                update_fields.append('compression_ratio = ?')
                params.append(compression_ratio)

            if compressed_filename is not None:
                update_fields.append('compressed_filename = ?')
                params.append(compressed_filename)

            params.append(transaction_id)

            query = f'''
                UPDATE transactions
                SET {', '.join(update_fields)}
                WHERE id = ?
            '''

            cursor.execute(query, params)
            conn.commit()
            conn.close()

            logger.info(f"Updated compression status for transaction {transaction_id}: {status}")
        except Exception as e:
            logger.error(f"Error updating compression status: {e}")
            raise

    def get_pending_compressions(self) -> List[Dict]:
        """
        Get all transactions with pending compression status.

        Returns:
            List of transaction dictionaries awaiting compression
        """
        try:
            conn = self.get_connection()
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()

            cursor.execute('''
                SELECT * FROM transactions
                WHERE compression_status = 'pending'
                AND end_time IS NOT NULL
                ORDER BY created_at ASC
            ''')

            rows = cursor.fetchall()
            transactions = [dict(row) for row in rows]

            conn.close()
            logger.info(f"Found {len(transactions)} pending compressions")
            return transactions
        except Exception as e:
            logger.error(f"Error fetching pending compressions: {e}")
            return []
