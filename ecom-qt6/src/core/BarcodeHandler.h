#pragma once

#include <QObject>
#include <QString>

struct BarcodeResult
{
    enum Action { Invalid, Start, StopAndStart };
    Action action;
    QString barcode;
};

class BarcodeHandler : public QObject
{
    Q_OBJECT

public:
    explicit BarcodeHandler(QObject *parent = nullptr);

    BarcodeResult processBarcode(const QString &barcode, bool isRecording);
    bool validateBarcode(const QString &barcode) const;
    QString lastBarcode() const;

private:
    QString m_lastBarcode;
};
