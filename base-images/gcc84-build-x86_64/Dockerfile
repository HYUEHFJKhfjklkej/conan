# gcc84-build-x86_64 — x86_64 toolchain base image for legacy .nupkg builds.
#
# Reconstructed verbatim from the Bitbucket "Source" view of
# gcc84-build-x86_64/Dockerfile @ branch develop, photographed 2026-05-04
# (photos/2026-05-04/INDEX.md, photo_2026-05-04_16-54-37.jpg — fully legible).
#
# Image chain:  nuget:4.8.1 -> build-tools:0.1.0 -> gcc84-build-x86_64
# Published as: proget.inc.elara.local/main/library/gcc84-build-x86_64:<tag>
#
# Closed-network specifics carried over as-is: apt goes through the
# 172.17.0.153:8080 proxy, Debian Stretch via archive.debian.org, custom
# *-devel-elara debs from the ProGet `debian` feed. GCC 8.4 is the default
# compiler via update-alternatives; 5.3 is a lower-priority fallback.

FROM proget.inc.elara.local/main/library/build-tools:0.1.0

RUN echo "Acquire::http::Proxy \"http://servers2:servers@172.17.0.153:8080\";" > /etc/apt/apt.conf
RUN echo "Acquire::https::Proxy \"http://servers2:servers@172.17.0.153:8080\";" >> /etc/apt/apt.conf
RUN echo "Acquire::Retries \"10\";" > /etc/apt/apt.conf.d/80-retries

RUN echo "deb [trusted=yes] http://proget.inc.elara.local/ debian main" > /etc/apt/sources.list.d/proget-elara.list
RUN echo "deb [trusted=yes] http://archive.debian.org/debian stretch main contrib non-free" > /etc/apt/sources.list

RUN apt update && apt install -y mesa-common-dev libglu1-mesa-dev qt5-devel-elara gcc84-devel-elara gcc53-devel-elara linuxdeployqt-devel-elara pvs-studio curl && rm -rf /var/lib/apt/lists/* && rm -f *.deb

RUN echo "" >> /etc/apt/apt.conf
RUN echo "" >> /etc/apt/sources.list

RUN update-alternatives --install /usr/bin/cc   cc   /usr/local/gcc-8.4/bin/gcc-8.4   40
RUN update-alternatives --install /usr/bin/c++  c++  /usr/local/gcc-8.4/bin/g++-8.4   40
RUN update-alternatives --install /usr/bin/gcov gcov /usr/local/gcc-8.4/bin/gcov-8.4  40

RUN update-alternatives --install /usr/bin/cc   cc   /usr/local/gcc-5.3/bin/gcc-5.3   10
RUN update-alternatives --install /usr/bin/c++  c++  /usr/local/gcc-5.3/bin/g++-5.3   10
RUN update-alternatives --install /usr/bin/gcov gcov /usr/local/gcc-5.3/bin/gcov-5.3  10

RUN update-alternatives --set cc  /usr/local/gcc-8.4/bin/gcc-8.4
RUN update-alternatives --set c++ /usr/local/gcc-8.4/bin/g++-8.4

RUN echo "/opt/Qt/5.15.2/gcc_64/lib" > /etc/ld.so.conf.d/linuxdeployqt.conf
RUN ldconfig

ENV QT5_ROOT_DIR="/opt/Qt/5.15.2"
ENV QT_QPA_PLATFORM="offscreen"
ENV PATH="$PATH:/opt/linuxdeployqt"

CMD ["bash"]
