FROM mcr.microsoft.com/powershell

RUN apt-get update && \
    apt-get install -y --no-install-recommends p7zip-full tzdata && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* \
# Locale support ru_RU and timezone CET
    localedef -i ru_RU -f UTF-8 POSIX && \
    echo "LANG=\"POSIX\"" > /etc/locale.conf && \
    ln -s -f /usr/share/zoneinfo/CET /etc/localtime
ENV LANG POSIX
ENV LANGUAGE POSIX
ENV LC_ALL POSIX
# Locale Support END ###

WORKDIR /pwd
COPY . .

VOLUME ["/pwd/config", "/pwd/stash"]

ENTRYPOINT ["pwsh", "/pwd/RT_run.ps1"]
