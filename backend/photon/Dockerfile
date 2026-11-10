# Our own place search (Photon, OpenStreetMap data) with Iraq only: fast,
# no limits, no key, no cost per search. The public photon.komoot.io blocks
# servers that search a lot, which broke search for the app.
#
#   docker compose up -d --build photon   # the first start loads Iraq (a few minutes)
#
# On Railway: a separate service from this folder, with a volume at
# /photon/data (so Iraq is loaded once), then set PHOTON_URL on the API to
# its private address, e.g. http://photon.railway.internal:2322
FROM eclipse-temurin:21-jre

ARG PHOTON_VERSION=1.3.0
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl zstd jq ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /photon
RUN curl -fsSL -o photon.jar \
      "https://github.com/komoot/photon/releases/download/${PHOTON_VERSION}/photon-${PHOTON_VERSION}.jar"
COPY start.sh prepare.jq /photon/
RUN chmod +x /photon/start.sh

# Iraq's places, with their Arabic, Kurdish (Kurmanji, Sorani) and English names.
# (prepare.jq adds the simplified spelling of Arabic and Kurdish names, so
# أربيل is also found as اربيل.)
ENV PHOTON_DUMP_URL=https://download1.graphhopper.com/public/asia/iraq/photon-dump-iraq-1.0-latest.jsonl.zst \
    PHOTON_LANGUAGES=en,ar,ku,ckb \
    PHOTON_DATA=/photon/data \
    JAVA_OPTS="-Xmx1g"

EXPOSE 2322
CMD ["/photon/start.sh"]
