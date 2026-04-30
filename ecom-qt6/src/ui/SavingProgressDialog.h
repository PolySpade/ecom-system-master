#pragma once

#include <QDialog>
#include <QProgressBar>
#include <QLabel>

class SavingProgressDialog : public QDialog {
    Q_OBJECT
public:
    explicit SavingProgressDialog(QWidget *parent = nullptr, const QString &title = "Saving Recording");
    void updateStatus(const QString &text, const QString &detail = "");

protected:
    void closeEvent(QCloseEvent *event) override;

private:
    QLabel *m_statusLabel;
    QLabel *m_detailLabel;
    QProgressBar *m_progressBar;
};
