# build-tools:0.1.0 — common build tooling layer (cmake, protoc, clang-tools,
# lcov, etc.) shared by gcc84-build-x86_64 and the gcc75 ARM toolchain images.
#
# Reconstructed from the Bitbucket "Source" view of build-tools/Dockerfile,
# photographed 2026-05-04 (photos/2026-05-04/INDEX.md,
# photo_2026-05-04_16-57-53.jpg). That photo is heavily color-fringed and
# partly blurred — the apt-install package names are only PARTIALLY legible.
# Lines flagged << VERIFY >> below need checking against Bitbucket before this
# is treated as authoritative.
#
# Image chain:  nuget:4.8.1 -> build-tools:0.1.0 -> gcc84-build-x86_64
# Published as: proget.inc.elara.local/main/library/build-tools:0.1.0

# << VERIFY >> base tag illegible in the photo (shown as "<base>:0.0.1").
# Memory/infra notes the chain root is nuget:4.8.1 (Mono + NuGet CLI). Confirm
# the exact name:tag in Bitbucket.
FROM proget.inc.elara.local/main/library/nuget:4.8.1

RUN echo "Acquire::http::Proxy \"http://servers2:servers@172.17.0.153:8080\";" > /etc/apt/apt.conf
RUN echo "Acquire::https::Proxy \"http://servers2:servers@172.17.0.153:8080\";" >> /etc/apt/apt.conf
RUN echo "Acquire::Retries \"10\";" >> /etc/apt/apt.conf.d/80-retries

RUN echo "deb [trusted=yes] http://archive.debian.org/debian stretch main contrib non-free" > /etc/apt/sources.list
RUN echo "deb [trusted=yes] http://proget.inc.elara.local/ debian main" > /etc/apt/sources.list.d/proget-elara.list
RUN apt update && apt upgrade -y && rm -rf /var/lib/apt/lists/*

RUN echo "" > /etc/apt/sources.list
RUN echo "" > /etc/apt/apt.conf
RUN echo "deb [trusted=yes] http://proget.inc.elara.local/ debian main" > /etc/apt/sources.list.d/proget-elara.list
# << VERIFY >> package names below are only partially legible in the photo.
RUN apt update && apt install -y cmake-devel-elara protoc-devel-elara lang-devel-elara linux-devel-elara cpplint-devel-elara pvslibqt-devel-elara && rm -rf /var/lib/apt/lists/*

RUN echo "" > /etc/apt/sources.list
RUN echo "deb [trusted=yes] http://proget.inc.elara.local/ debian main" > /etc/apt/sources.list.d/proget-elara.list
RUN echo "" > /etc/apt/apt.conf
RUN echo "" > /etc/apt/sources.list

CMD ["bash"]
