#!/bin/sh
# Переподписывает собранное приложение сертификатом Apple Development.
#
# Сборка по умолчанию подписывается ad-hoc (CODE_SIGN_IDENTITY: "-"). У такой подписи
# нет TeamIdentifier, поэтому macOS не может привязать выданные разрешения TCC к
# приложению и спрашивает «доступ к данным других приложений» при каждом запуске
# агента (он пишет историю в контейнер расширения виджета). Разовая подпись своим
# сертификатом разработки делает идентичность приложения стабильной, и после первого
# «Разрешить» вопрос больше не появляется.
#
# Использование: scripts/sign-local.sh [путь/к/SelectelSpeedtest.app]
set -e

APP="${1:-dist/SelectelSpeedtest.app}"
IDENT=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')
if [ -z "$IDENT" ]; then
    echo "Не найден сертификат Apple Development (см. security find-identity -v -p codesigning)" >&2
    exit 1
fi
echo "Подписываю «$APP»: $IDENT"
codesign --force --sign "$IDENT" --entitlements Widget/SpeedtestWidget.entitlements \
    "$APP/Contents/PlugIns/SpeedtestWidget.appex"
codesign --force --sign "$IDENT" "$APP"
