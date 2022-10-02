FROM mcr.microsoft.com/powershell

RUN apt-get update && \
    apt-get install -y --no-install-recommends p7zip-full tzdata locales && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
# Locale
ENV TZ Europe/Moscow
ENV LANG ru_RU.UTF-8
ENV LANGUAGE ru_RU:ru
ENV LC_LANG ru_RU.UTF-8
ENV LC_ALL ru_RU.UTF-8

RUN sed -i -e 's/# ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen && locale-gen && \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

WORKDIR /pwd
COPY . .

VOLUME ["/pwd/config", "/pwd/stash"]
ENTRYPOINT ["pwsh", "/pwd/RT_run.ps1"]
