#include "Database.h"

#include <QSqlDatabase>
#include <QSqlQuery>
#include <QSqlError>
#include <QSqlRecord>
#include <QThread>
#include <QUuid>
#include <QDateTime>
#include <QStringList>
#include <QVariantList>

Database::Database(const QString &dbPath, QObject *parent)
    : QObject(parent)
    , m_dbPath(dbPath)
    , m_baseConnectionName(QStringLiteral("ecom_db_") + QUuid::createUuid().toString(QUuid::Id128))
{
    initializeDatabase();
}

Database::~Database()
{
    QString connName = connectionName();
    if (QSqlDatabase::contains(connName)) {
        QSqlDatabase::removeDatabase(connName);
    }
}

QString Database::connectionName() const
{
    return m_baseConnectionName + QStringLiteral("_") +
           QString::number(reinterpret_cast<quintptr>(QThread::currentThread()));
}

void Database::initializeDatabase()
{
    QString connName = connectionName();

    {
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connName);
        db.setDatabaseName(m_dbPath);

        if (!db.open()) {
            return;
        }

        QSqlQuery query(db);
        query.exec(QStringLiteral(
            "CREATE TABLE IF NOT EXISTS transactions ("
            "    id INTEGER PRIMARY KEY AUTOINCREMENT,"
            "    barcode TEXT NOT NULL,"
            "    video_filename TEXT NOT NULL,"
            "    start_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,"
            "    end_time TIMESTAMP,"
            "    duration_seconds INTEGER,"
            "    file_size_mb REAL,"
            "    stop_method TEXT,"
            "    label TEXT DEFAULT 'Normal (Standard)',"
            "    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,"
            "    compression_status TEXT DEFAULT 'pending',"
            "    compressed_file_size_mb REAL,"
            "    compression_ratio REAL,"
            "    compressed_filename TEXT"
            ")"
        ));
    }
}

int Database::createTransaction(const QString &barcode, const QString &videoFilename, const QString &label)
{
    QString connName = connectionName();

    if (!QSqlDatabase::contains(connName)) {
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connName);
        db.setDatabaseName(m_dbPath);
        db.open();
    }

    QSqlDatabase db = QSqlDatabase::database(connName);
    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "INSERT INTO transactions (barcode, video_filename, label) VALUES (?, ?, ?)"
    ));
    query.addBindValue(barcode);
    query.addBindValue(videoFilename);
    query.addBindValue(label);

    if (query.exec()) {
        return query.lastInsertId().toInt();
    }
    return -1;
}

void Database::completeTransaction(int transactionId, int durationSeconds, double fileSizeMb,
                                   const QString &stopMethod)
{
    QString connName = connectionName();

    if (!QSqlDatabase::contains(connName)) {
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connName);
        db.setDatabaseName(m_dbPath);
        db.open();
    }

    QSqlDatabase db = QSqlDatabase::database(connName);
    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "UPDATE transactions SET end_time = CURRENT_TIMESTAMP, duration_seconds = ?, "
        "file_size_mb = ?, stop_method = ? WHERE id = ?"
    ));
    query.addBindValue(durationSeconds);
    query.addBindValue(fileSizeMb);
    query.addBindValue(stopMethod);
    query.addBindValue(transactionId);
    query.exec();
}

QList<QVariantMap> Database::getRecentTransactions(int limit)
{
    QString connName = connectionName();

    if (!QSqlDatabase::contains(connName)) {
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connName);
        db.setDatabaseName(m_dbPath);
        db.open();
    }

    QSqlDatabase db = QSqlDatabase::database(connName);
    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT * FROM transactions ORDER BY created_at DESC LIMIT ?"
    ));
    query.addBindValue(limit);
    query.exec();

    QList<QVariantMap> results;
    QSqlRecord record = query.record();

    while (query.next()) {
        QVariantMap row;
        for (int i = 0; i < record.count(); ++i) {
            row[record.fieldName(i)] = query.value(i);
        }
        results.append(row);
    }

    return results;
}

QVariantMap Database::advancedSearch(const QString &barcode, const QString &startDate,
                                     const QString &endDate, const QString &label,
                                     const QString &sortBy, const QString &sortOrder,
                                     int limit, int offset)
{
    QString connName = connectionName();

    if (!QSqlDatabase::contains(connName)) {
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connName);
        db.setDatabaseName(m_dbPath);
        db.open();
    }

    QSqlDatabase db = QSqlDatabase::database(connName);

    // Whitelist sortBy and sortOrder to prevent SQL injection
    static const QStringList allowedSortColumns = {
        "id", "barcode", "video_filename", "start_time", "end_time",
        "duration_seconds", "file_size_mb", "stop_method", "label",
        "created_at", "compression_status"
    };
    QString safeSortBy = allowedSortColumns.contains(sortBy) ? sortBy : QStringLiteral("created_at");
    QString safeSortOrder = (sortOrder.toUpper() == QStringLiteral("ASC")) ?
                            QStringLiteral("ASC") : QStringLiteral("DESC");

    // Build WHERE clause
    QStringList conditions;
    QVariantList bindValues;

    if (!barcode.isEmpty()) {
        conditions.append(QStringLiteral("barcode LIKE ?"));
        bindValues.append(QStringLiteral("%") + barcode + QStringLiteral("%"));
    }
    if (!startDate.isEmpty()) {
        conditions.append(QStringLiteral("created_at >= ?"));
        bindValues.append(startDate);
    }
    if (!endDate.isEmpty()) {
        conditions.append(QStringLiteral("created_at <= ?"));
        bindValues.append(endDate);
    }
    if (!label.isEmpty()) {
        conditions.append(QStringLiteral("label = ?"));
        bindValues.append(label);
    }

    QString whereClause;
    if (!conditions.isEmpty()) {
        whereClause = QStringLiteral(" WHERE ") + conditions.join(QStringLiteral(" AND "));
    }

    // Count total
    QSqlQuery countQuery(db);
    countQuery.prepare(QStringLiteral("SELECT COUNT(*) FROM transactions") + whereClause);
    for (const QVariant &val : bindValues) {
        countQuery.addBindValue(val);
    }
    countQuery.exec();
    int total = 0;
    if (countQuery.next()) {
        total = countQuery.value(0).toInt();
    }

    // Fetch results
    QString sql = QStringLiteral("SELECT * FROM transactions") + whereClause +
                  QStringLiteral(" ORDER BY ") + safeSortBy + QStringLiteral(" ") + safeSortOrder;

    if (limit > 0) {
        sql += QStringLiteral(" LIMIT ? OFFSET ?");
    }

    QSqlQuery query(db);
    query.prepare(sql);
    for (const QVariant &val : bindValues) {
        query.addBindValue(val);
    }
    if (limit > 0) {
        query.addBindValue(limit);
        query.addBindValue(offset);
    }
    query.exec();

    QVariantList results;
    QSqlRecord record = query.record();

    while (query.next()) {
        QVariantMap row;
        for (int i = 0; i < record.count(); ++i) {
            row[record.fieldName(i)] = query.value(i);
        }
        results.append(row);
    }

    QVariantMap result;
    result["results"] = results;
    result["total"] = total;
    return result;
}

void Database::updateCompressionStatus(int transactionId, const QString &status,
                                       double compressedFileSizeMb, double compressionRatio,
                                       const QString &compressedFilename)
{
    QString connName = connectionName();

    if (!QSqlDatabase::contains(connName)) {
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connName);
        db.setDatabaseName(m_dbPath);
        db.open();
    }

    QSqlDatabase db = QSqlDatabase::database(connName);
    QSqlQuery query(db);

    QString sql = QStringLiteral("UPDATE transactions SET compression_status = ?");
    QVariantList bindValues;
    bindValues.append(status);

    if (compressedFileSizeMb >= 0) {
        sql += QStringLiteral(", compressed_file_size_mb = ?");
        bindValues.append(compressedFileSizeMb);
    }
    if (compressionRatio >= 0) {
        sql += QStringLiteral(", compression_ratio = ?");
        bindValues.append(compressionRatio);
    }
    if (!compressedFilename.isEmpty()) {
        sql += QStringLiteral(", compressed_filename = ?");
        bindValues.append(compressedFilename);
    }

    sql += QStringLiteral(" WHERE id = ?");
    bindValues.append(transactionId);

    query.prepare(sql);
    for (const QVariant &val : bindValues) {
        query.addBindValue(val);
    }
    query.exec();
}

double Database::getTotalStorageUsed()
{
    QString connName = connectionName();

    if (!QSqlDatabase::contains(connName)) {
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connName);
        db.setDatabaseName(m_dbPath);
        db.open();
    }

    QSqlDatabase db = QSqlDatabase::database(connName);
    QSqlQuery query(db);
    query.exec(QStringLiteral(
        "SELECT COALESCE(SUM(file_size_mb), 0) FROM transactions"
    ));

    if (query.next()) {
        return query.value(0).toDouble();
    }
    return 0.0;
}

QList<QVariantMap> Database::getPendingCompressions()
{
    QString connName = connectionName();

    if (!QSqlDatabase::contains(connName)) {
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connName);
        db.setDatabaseName(m_dbPath);
        db.open();
    }

    QSqlDatabase db = QSqlDatabase::database(connName);
    QSqlQuery query(db);
    query.exec(QStringLiteral(
        "SELECT * FROM transactions WHERE compression_status = 'pending' "
        "AND end_time IS NOT NULL ORDER BY created_at ASC"
    ));

    QList<QVariantMap> results;
    QSqlRecord record = query.record();

    while (query.next()) {
        QVariantMap row;
        for (int i = 0; i < record.count(); ++i) {
            row[record.fieldName(i)] = query.value(i);
        }
        results.append(row);
    }

    return results;
}
