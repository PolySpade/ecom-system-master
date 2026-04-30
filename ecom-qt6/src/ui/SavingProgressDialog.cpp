#include "ui/SavingProgressDialog.h"
#include <QVBoxLayout>
#include <QCloseEvent>

SavingProgressDialog::SavingProgressDialog(QWidget *parent, const QString &title)
    : QDialog(parent)
{
    setWindowTitle(title);
    setFixedSize(350, 120);
    setModal(true);
    setWindowFlags(windowFlags() & ~Qt::WindowCloseButtonHint);

    auto *layout = new QVBoxLayout(this);
    layout->setContentsMargins(20, 16, 20, 16);
    layout->setSpacing(8);

    m_statusLabel = new QLabel("Saving recording...");
    m_statusLabel->setStyleSheet("font-size: 14px; font-weight: bold; color: #1e293b;");
    layout->addWidget(m_statusLabel);

    m_detailLabel = new QLabel("Writing remaining frames...");
    m_detailLabel->setStyleSheet("font-size: 12px; color: #64748b;");
    layout->addWidget(m_detailLabel);

    m_progressBar = new QProgressBar;
    m_progressBar->setRange(0, 0); // indeterminate
    m_progressBar->setFixedHeight(8);
    m_progressBar->setTextVisible(false);
    layout->addWidget(m_progressBar);
}

void SavingProgressDialog::updateStatus(const QString &text, const QString &detail)
{
    m_statusLabel->setText(text);
    if (!detail.isEmpty()) {
        m_detailLabel->setText(detail);
    }
}

void SavingProgressDialog::closeEvent(QCloseEvent *event)
{
    event->ignore();
}
