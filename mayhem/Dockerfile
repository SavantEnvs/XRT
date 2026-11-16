# syntax=docker/dockerfile:1.7
# Commit image: the org C/C++ base plus the per-commit build of XRT's host-side xclbin and
# firmware-image parsers (mayhem/build.sh) and its oracle (mayhem/test.sh).
FROM ghcr.io/savantenvs/base:20261023

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# XRT's own submodules (core/common/{aiebu,elf}) are absent from the build context, so the two
# sources the host-side core needs are pinned here at the exact commits XRT's gitlinks name:
# aiebu (ELF/ctrlcode reader pulled in through xrt::hw_context/kernel/elf) and ELFIO (headers).
# boost, libuuid, libzstd and GSL come from apt; rapidjson, gtest, boost program_options and
# OpenSSL are for upstream's xclbinutil/xclbintest suite (mayhem/test.sh runs it with ctest).
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
        libboost-dev libboost-filesystem-dev libboost-system-dev libmsgsl-dev uuid-dev libzstd-dev \
        libboost-program-options-dev rapidjson-dev libgtest-dev libssl-dev openssl \
 && rm -rf /var/lib/apt/lists/*
ARG AIEBU_COMMIT=1b398e72a3ef1ad6e1af4d0f63997af523952e6a
ARG ELFIO_COMMIT=f849001fc229c2598f8557e0df22866af194ef98
RUN set -e; \
    fetch() { d="$1"; url="$2"; sha="$3"; mkdir -p "$d/src"; cd "$d/src"; git init -q .; \
              git remote add origin "$url"; git fetch -q --depth 1 origin "$sha"; \
              git checkout -q FETCH_HEAD; test "$(git rev-parse HEAD)" = "$sha"; cd /; }; \
    fetch /opt/toolchains/deps/aiebu-1b398e72 https://github.com/Xilinx/aiebu.git "$AIEBU_COMMIT"; \
    fetch /opt/toolchains/deps/elfio-f849001f https://github.com/serge1/ELFIO.git "$ELFIO_COMMIT"; \
    chmod -R a+rX /opt/toolchains/deps
USER mayhem

WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN if [ -x /opt/mayhem/ccache/prefill ]; then /opt/mayhem/ccache/prefill bash mayhem/build.sh; \
    else bash mayhem/build.sh; fi

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
