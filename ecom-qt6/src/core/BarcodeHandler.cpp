#include "BarcodeHandler.h"

BarcodeHandler::BarcodeHandler(QObject *parent)
    : QObject(parent)
{
}

BarcodeResult BarcodeHandler::processBarcode(const QString &barcode, bool isRecording)
{
    QString cleaned = barcode.trimmed().toUpper();

    if (!validateBarcode(cleaned)) {
        return BarcodeResult{BarcodeResult::Invalid, QString()};
    }

    m_lastBarcode = cleaned;

    if (isRecording) {
        return BarcodeResult{BarcodeResult::StopAndStart, cleaned};
    }

    return BarcodeResult{BarcodeResult::Start, cleaned};
}

bool BarcodeHandler::validateBarcode(const QString &barcode) const
{
    return !barcode.trimmed().isEmpty();
}

QString BarcodeHandler::lastBarcode() const
{
    return m_lastBarcode;
}
