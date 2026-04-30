#pragma once

#include <QObject>
#include <QString>
#include <QList>
#include <QVariantMap>

class Database : public QObject
{
    Q_OBJECT

public:
    explicit Database(const QString &dbPath, QObject *parent = nullptr);
    ~Database();

    int createTransaction(const QString &barcode, const QString &videoFilename,
                          const QString &label = QStringLiteral("Normal (Standard)"));
    void completeTransaction(int transactionId, int durationSeconds, double fileSizeMb,
                             const QString &stopMethod);
    QList<QVariantMap> getRecentTransactions(int limit = 10);
    QVariantMap advancedSearch(const QString &barcode = QString(),
                               const QString &startDate = QString(),
                               const QString &endDate = QString(),
                               const QString &label = QString(),
                               const QString &sortBy = QStringLiteral("created_at"),
                               const QString &sortOrder = QStringLiteral("DESC"),
                               int limit = -1, int offset = 0);
    void updateCompressionStatus(int transactionId, const QString &status,
                                 double compressedFileSizeMb = -1,
                                 double compressionRatio = -1,
                                 const QString &compressedFilename = QString());
    double getTotalStorageUsed();
    QList<QVariantMap> getPendingCompressions();

private:
    void initializeDatabase();
    QString connectionName() const;

    QString m_dbPath;
    QString m_baseConnectionName;
};
