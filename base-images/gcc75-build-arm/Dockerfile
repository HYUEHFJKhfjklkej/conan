# gcc75-build-arm — armv7hf cross-toolchain base image (linaro 7.5-2019.12).
#
# !!! SCAFFOLD — NOT reconstructed from source. !!!
# Unlike gcc84-build-x86_64/build-tools (transcribed from 2026-05-04 Bitbucket
# photos), there is NO photo or transcript of the real gcc75-build-arm
# Dockerfile anywhere in this workspace. The structure below is modelled on
# gcc84-build-x86_64 (same proxy/feed boilerplate) plus the linaro paths the
# Conan profiles already assume. Every << TODO >> must be filled from the real
# Bitbucket source (or your reworked version) before this is built/published.
#
# Image chain:  build-tools:0.1.0 -> gcc75-build-arm
# Published as: proget.inc.elara.local/main/library/gcc75-build-arm:<tag>
#
# Contract the profiles rely on (profiles/lin-gcc75-arm-linaro +
# profiles/toolchains/linaro-arm.cmake): the cross gcc must live under
#   /opt/linaro-arm-7.5.0/gcc-linaro-7.5.0-2019.12-rc1-x86_64_arm-linux-gnueabihf/
# with bin/arm-linux-gnueabihf-{gcc,g++,...} and ld.gold present.

FROM proget.inc.elara.local/main/library/build-tools:0.1.0

RUN echo "Acquire::http::Proxy \"http://servers2:servers@172.17.0.153:8080\";" > /etc/apt/apt.conf
RUN echo "Acquire::https::Proxy \"http://servers2:servers@172.17.0.153:8080\";" >> /etc/apt/apt.conf
RUN echo "Acquire::Retries \"10\";" > /etc/apt/apt.conf.d/80-retries

RUN echo "deb [trusted=yes] http://proget.inc.elara.local/ debian main" > /etc/apt/sources.list.d/proget-elara.list
RUN echo "deb [trusted=yes] http://archive.debian.org/debian stretch main contrib non-free" > /etc/apt/sources.list

# << TODO >> install the linaro 7.5-2019.12 armv7hf cross toolchain into
# /opt/linaro-arm-7.5.0/. In CI this is most likely a custom *-devel-elara deb
# from the ProGet debian feed (mirror gcc84-devel-elara), OR an ADD/COPY of the
# gcc-linaro-7.5.0-2019.12-rc1-x86_64_arm-linux-gnueabihf.tar.xz tarball.
# Replace the placeholder line with the real mechanism:
#   RUN apt update && apt install -y linaro-arm-7.5-devel-elara && rm -rf /var/lib/apt/lists/* && rm -f *.deb
# or:
#   ADD gcc-linaro-7.5.0-2019.12-rc1-x86_64_arm-linux-gnueabihf.tar.xz /opt/linaro-arm-7.5.0/
RUN echo "gcc75-build-arm is a SCAFFOLD — fill the linaro 7.5 armv7hf install above (see base-images/README.md)" >&2 && exit 1

RUN echo "" >> /etc/apt/apt.conf
RUN echo "" >> /etc/apt/sources.list

CMD ["bash"]
