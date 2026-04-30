#pragma once

#include <QDialog>
#include <QLineEdit>
#include <QComboBox>
#include <QDateEdit>
#include <QPushButton>
#include <QScrollArea>
#include <QVBoxLayout>

class Database;
class SettingsManager;

class SearchDialog : public QDialog {
    Q_OBJECT
public:
    explicit SearchDialog(Database *db, SettingsManager *settings, QWidget *parent = nullptr);

private slots:
    void performSearch();
    void clearFilters();

private:
    void setupUi();
    QWidget *createResultCard(const QVariantMap &record);

    Database *m_db;
    SettingsManager *m_settings;

    QLineEdit *m_barcodeFilter;
    QComboBox *m_labelFilter;
    QDateEdit *m_startDate;
    QDateEdit *m_endDate;
    QComboBox *m_sortBy;
    QPushButton *m_searchButton;
    QPushButton *m_clearButton;
    QScrollArea *m_scrollArea;
    QVBoxLayout *m_resultsLayout;
    QWidget *m_resultsContainer;
};
