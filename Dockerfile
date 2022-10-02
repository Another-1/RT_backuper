FROM mcr.microsoft.com/powershell

ENV LANG POSIX
ENV TZ Europe/Moscow
ENV LANGUAGE POSIX
ENV LC_ALL POSIX

RUN apt-get update && \
    apt-get install -y --no-install-recommends p7zip-full tzdata && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* \
# Locale support ru_RU and timezone CET
    localedef -i ru_RU -f UTF-8 POSIX && \
    echo "LANG=\"POSIX\"" > /etc/locale.conf && \
    ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime && \
    echo "${TZ}" > /etc/timezone && date
# Locale Support END ###

WORKDIR /pwd
COPY . .

VOLUME ["/pwd/config", "/pwd/stash"]

ENTRYPOINT ["pwsh", "/pwd/RT_run.ps1"]
