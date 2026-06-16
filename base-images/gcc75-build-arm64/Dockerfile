# gcc75-build-arm64 — aarch64 cross-toolchain base image (linaro 7.5-2019.12).
#
# !!! SCAFFOLD — NOT reconstructed from source. !!!
# No photo or transcript of the real gcc75-build-arm64 Dockerfile exists in this
# workspace. Modelled on gcc84-build-x86_64 + the linaro paths the Conan
# profiles assume. Fill every << TODO >> from the real Bitbucket source (or your
# reworked version) before building/publishing.
#
# Image chain:  build-tools:0.1.0 -> gcc75-build-arm64
# Published as: proget.inc.elara.local/main/library/gcc75-build-arm64:<tag>
#
# Contract the profiles rely on (profiles/lin-gcc-aarch64-linaro +
# profiles/toolchains/linaro-aarch64.cmake): the cross gcc must live under
#   /opt/linaro-arm64-7.5.0/gcc-linaro-7.5.0-2019.12-rc1-x86_64_aarch64-linux-gnu/
# with bin/aarch64-linux-gnu-{gcc,g++,...} and ld.gold present.
# NOTE: the directory is linaro-arm64 (not linaro-aarch64) — CI naming quirk.

FROM proget.inc.elara.local/main/library/build-tools:0.1.0

RUN echo "Acquire::http::Proxy \"http://servers2:servers@172.17.0.153:8080\";" > /etc/apt/apt.conf
RUN echo "Acquire::https::Proxy \"http://servers2:servers@172.17.0.153:8080\";" >> /etc/apt/apt.conf
RUN echo "Acquire::Retries \"10\";" > /etc/apt/apt.conf.d/80-retries

RUN echo "deb [trusted=yes] http://proget.inc.elara.local/ debian main" > /etc/apt/sources.list.d/proget-elara.list
RUN echo "deb [trusted=yes] http://archive.debian.org/debian stretch main contrib non-free" > /etc/apt/sources.list

# << TODO >> install the linaro 7.5-2019.12 aarch64 cross toolchain into
# /opt/linaro-arm64-7.5.0/. Same mechanism question as the armv7hf image:
#   RUN apt update && apt install -y linaro-arm64-7.5-devel-elara && rm -rf /var/lib/apt/lists/* && rm -f *.deb
# or:
#   ADD gcc-linaro-7.5.0-2019.12-rc1-x86_64_aarch64-linux-gnu.tar.xz /opt/linaro-arm64-7.5.0/
RUN echo "gcc75-build-arm64 is a SCAFFOLD — fill the linaro 7.5 aarch64 install above (see base-images/README.md)" >&2 && exit 1

RUN echo "" >> /etc/apt/apt.conf
RUN echo "" >> /etc/apt/sources.list

CMD ["bash"]
