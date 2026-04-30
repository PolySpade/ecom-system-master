#include "ui/SearchDialog.h"
#include "core/Database.h"
#include "core/SettingsManager.h"

#include <QGridLayout>
#include <QHBoxLayout>
#include <QVBoxLayout>
#include <QFrame>
#include <QLabel>
#include <QDesktopServices>
#include <QUrl>
#include <QFileInfo>
#include <QDir>
#include <QProcess>

SearchDialog::SearchDialog(Database *db, SettingsManager *settings, QWidget *parent)
    : QDialog(parent), m_db(db), m_settings(settings)
{
    setupUi();
    performSearch();
}

void SearchDialog::setupUi()
{
    setWindowTitle("Search Recordings");
    resize(1000, 700);
    setMinimumSize(700, 500);

    auto *mainLayout = new QVBoxLayout(this);
    mainLayout->setContentsMargins(16, 16, 16, 16);
    mainLayout->setSpacing(12);

    // Filters row
    auto *filterFrame = new QFrame;
    filterFrame->setStyleSheet(
        "QFrame { background-color: white; border: 1px solid #e2e8f0; border-radius: 8px; padding: 8px; }");
    auto *filterLayout = new QGridLayout(filterFrame);
    filterLayout->setSpacing(8);

    // Barcode filter
    filterLayout->addWidget(new QLabel("Barcode:"), 0, 0);
    m_barcodeFilter = new QLineEdit;
    m_barcodeFilter->setPlaceholderText("Search barcode...");
    filterLayout->addWidget(m_barcodeFilter, 0, 1);

    // Label filter
    filterLayout->addWidget(new QLabel("Label:"), 0, 2);
    m_labelFilter = new QComboBox;
    m_labelFilter->addItems({"All", "Return and Refund Unboxing", "Return Parcel Unboxing", "Normal (Standard)"});
    filterLayout->addWidget(m_labelFilter, 0, 3);

    // Date filters
    filterLayout->addWidget(new QLabel("From:"), 1, 0);
    m_startDate = new QDateEdit;
    m_startDate->setCalendarPopup(true);
    m_startDate->setDate(QDate::currentDate().addMonths(-1));
    m_startDate->setDisplayFormat("yyyy-MM-dd");
    filterLayout->addWidget(m_startDate, 1, 1);

    filterLayout->addWidget(new QLabel("To:"), 1, 2);
    m_endDate = new QDateEdit;
    m_endDate->setCalendarPopup(true);
    m_endDate->setDate(QDate::currentDate());
    m_endDate->setDisplayFormat("yyyy-MM-dd");
    filterLayout->addWidget(m_endDate, 1, 3);

    // Sort by
    filterLayout->addWidget(new QLabel("Sort By:"), 2, 0);
    m_sortBy = new QComboBox;
    m_sortBy->addItems({"Date", "Barcode", "Duration", "Size"});
    filterLayout->addWidget(m_sortBy, 2, 1);

    // Buttons
    auto *btnLayout = new QHBoxLayout;
    m_searchButton = new QPushButton("Search");
    m_searchButton->setObjectName("primaryButton");
    connect(m_searchButton, &QPushButton::clicked, this, &SearchDialog::performSearch);
    btnLayout->addWidget(m_searchButton);

    m_clearButton = new QPushButton("Clear");
    connect(m_clearButton, &QPushButton::clicked, this, &SearchDialog::clearFilters);
    btnLayout->addWidget(m_clearButton);
    btnLayout->addStretch();

    filterLayout->addLayout(btnLayout, 2, 2, 1, 2);

    mainLayout->addWidget(filterFrame);

    // Results scroll area
    m_scrollArea = new QScrollArea;
    m_scrollArea->setWidgetResizable(true);
    m_scrollArea->setStyleSheet("QScrollArea { border: none; background-color: transparent; }");

    m_resultsContainer = new QWidget;
    m_resultsLayout = new QVBoxLayout(m_resultsContainer);
    m_resultsLayout->setContentsMargins(0, 0, 0, 0);
    m_resultsLayout->setSpacing(8);
    m_resultsLayout->addStretch();

    m_scrollArea->setWidget(m_resultsContainer);
    mainLayout->addWidget(m_scrollArea, 1);
}

void SearchDialog::performSearch()
{
    QString barcode = m_barcodeFilter->text().trimmed();
    QString label = m_labelFilter->currentIndex() == 0 ? "" : m_labelFilter->currentText();
    QString startDate = m_startDate->date().toString("yyyy-MM-dd");
    QString endDate = m_endDate->date().toString("yyyy-MM-dd");

    // Map sort combo to DB column
    QStringList sortColumns = {"created_at", "barcode", "duration_seconds", "file_size_mb"};
    QString sortBy = sortColumns.value(m_sortBy->currentIndex(), "created_at");

    QVariantMap results = m_db->advancedSearch(barcode, startDate, endDate, label, sortBy, "DESC");
    QVariantList resultList = results.value("results").toList();
    QList<QVariantMap> records;
    for (const QVariant &v : resultList) {
        records.append(v.toMap());
    }

    // Clear existing results
    while (m_resultsLayout->count() > 1) {
        QLayoutItem *item = m_resultsLayout->takeAt(0);
        if (item->widget()) {
            item->widget()->deleteLater();
        }
        delete item;
    }

    if (records.isEmpty()) {
        auto *noResults = new QLabel("No recordings found.");
        noResults->setAlignment(Qt::AlignCenter);
        noResults->setStyleSheet("color: #64748b; font-size: 14px; padding: 40px;");
        m_resultsLayout->insertWidget(0, noResults);
        return;
    }

    for (int i = 0; i < records.size(); ++i) {
        m_resultsLayout->insertWidget(i, createResultCard(records[i]));
    }
}

QWidget *SearchDialog::createResultCard(const QVariantMap &record)
{
    auto *card = new QFrame;
    card->setStyleSheet(
        "QFrame { background-color: white; border: 1px solid #e2e8f0; border-radius: 8px; padding: 12px; }");

    auto *layout = new QVBoxLayout(card);
    layout->setSpacing(6);

    // Top row: barcode + label badge
    auto *topRow = new QHBoxLayout;
    auto *barcodeLabel = new QLabel(record.value("barcode").toString());
    barcodeLabel->setStyleSheet("font-size: 16px; font-weight: bold; color: #1e293b; border: none;");
    topRow->addWidget(barcodeLabel);

    QString labelText = record.value("label").toString();
    auto *badge = new QLabel(labelText);
    QString badgeColor = "#667eea";
    if (labelText.contains("Refund")) badgeColor = "#f59e0b";
    else if (labelText.contains("Parcel")) badgeColor = "#8b5cf6";
    badge->setStyleSheet(QString(
        "background-color: %1; color: white; font-size: 11px; font-weight: bold; "
        "border-radius: 4px; padding: 2px 8px; border: none;").arg(badgeColor));
    badge->setFixedHeight(22);
    topRow->addWidget(badge);
    topRow->addStretch();
    layout->addLayout(topRow);

    // Detail rows
    int duration = record.value("duration_seconds", 0).toInt();
    double sizeMb = record.value("file_size_mb", 0).toDouble();
    QString date = record.value("created_at").toString();
    QString filename = record.value("video_filename").toString();

    auto *detailLabel = new QLabel(QString("Date: %1  |  Duration: %2:%3  |  Size: %4 MB")
                                       .arg(date.left(19))
                                       .arg(duration / 60, 2, 10, QChar('0'))
                                       .arg(duration % 60, 2, 10, QChar('0'))
                                       .arg(sizeMb, 0, 'f', 2));
    detailLabel->setStyleSheet("font-size: 12px; color: #64748b; border: none;");
    layout->addWidget(detailLabel);

    auto *fileLabel = new QLabel("File: " + filename);
    fileLabel->setStyleSheet("font-size: 11px; color: #94a3b8; border: none;");
    layout->addWidget(fileLabel);

    // Action buttons
    auto *btnRow = new QHBoxLayout;

    // video_filename stores the full path from CameraHandler
    QString fullPath = filename;

    auto *playBtn = new QPushButton("Play Video");
    playBtn->setObjectName("primaryButton");
    playBtn->setFixedHeight(30);
    connect(playBtn, &QPushButton::clicked, this, [fullPath]() {
        QDesktopServices::openUrl(QUrl::fromLocalFile(fullPath));
    });
    btnRow->addWidget(playBtn);

    auto *folderBtn = new QPushButton("Show in Folder");
    folderBtn->setFixedHeight(30);
    connect(folderBtn, &QPushButton::clicked, this, [fullPath]() {
#ifdef Q_OS_WIN
        QProcess::startDetached("explorer", {"/select,", QDir::toNativeSeparators(fullPath)});
#else
        QDesktopServices::openUrl(QUrl::fromLocalFile(QFileInfo(fullPath).dir().absolutePath()));
#endif
    });
    btnRow->addWidget(folderBtn);
    btnRow->addStretch();

    layout->addLayout(btnRow);
    return card;
}

void SearchDialog::clearFilters()
{
    m_barcodeFilter->clear();
    m_labelFilter->setCurrentIndex(0);
    m_startDate->setDate(QDate::currentDate().addMonths(-1));
    m_endDate->setDate(QDate::currentDate());
    m_sortBy->setCurrentIndex(0);
    performSearch();
}
