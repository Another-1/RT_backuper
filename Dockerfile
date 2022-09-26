FROM mcr.microsoft.com/powershell

RUN apt-get update && \
    apt-get install -y --no-install-recommends p7zip-full tzdata && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /pwd
COPY . .

VOLUME ["/pwd/config"]
CMD ["pwsh", "/pwd/RT_run.ps1"]
