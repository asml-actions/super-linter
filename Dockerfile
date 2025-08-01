####################################
####################################
## Dockerfile to run Super-Linter ##
####################################
####################################

#########################################
# Get dependency images as build stages #
#########################################
FROM tenable/terrascan:1.19.9 as terrascan
FROM alpine/terragrunt:1.12.2 as terragrunt
FROM dotenvlinter/dotenv-linter:3.3.0 as dotenv-linter
FROM ghcr.io/terraform-linters/tflint:v0.58.1 as tflint
FROM ghcr.io/yannh/kubeconform:v0.7.0 as kubeconfrm
FROM golang:1.24.5-alpine as golang
FROM golangci/golangci-lint:v2.2.1 as golangci-lint
FROM hadolint/hadolint:v2.12.0-alpine as dockerfile-lint
FROM hashicorp/terraform:1.12.0 as terraform
FROM koalaman/shellcheck:v0.10.0 as shellcheck
FROM mstruebing/editorconfig-checker:v3.3.0 as editorconfig-checker
FROM mvdan/shfmt:v3.12.0 as shfmt
FROM rhysd/actionlint:1.7.7 as actionlint
FROM scalameta/scalafmt:v3.9.8 as scalafmt
FROM zricethezav/gitleaks:v8.28.0 as gitleaks
FROM yoheimuta/protolint:0.55.6 as protolint
FROM ghcr.io/clj-kondo/clj-kondo:2025.06.05-alpine as clj-kondo
FROM dart:3.7.1-sdk as dart

FROM python:3.13.1-alpine3.19 as clang-format

RUN apk add --no-cache \
    build-base \
    clang17 \
    cmake \
    git \
    llvm17-dev \
    ninja-is-really-ninja

WORKDIR /tmp
RUN git clone \
    --branch "llvmorg-$(llvm-config  --version)" \
    --depth 1 \
    https://github.com/llvm/llvm-project.git

WORKDIR /tmp/llvm-project/llvm/build
RUN cmake \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DLLVM_BUILD_STATIC=ON \
    -DLLVM_ENABLE_PROJECTS=clang \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ .. \
    && ninja clang-format \
    && mv /tmp/llvm-project/llvm/build/bin/clang-format /usr/bin

FROM python:3.13.1-alpine3.19 as python-builder

RUN apk add --no-cache \
    bash

SHELL ["/bin/bash", "-o", "errexit", "-o", "nounset", "-o", "pipefail", "-c"]

COPY dependencies/python/ /stage
WORKDIR /stage
RUN ./build-venvs.sh && rm -rfv /stage

FROM python:3.13.1-alpine3.19 as npm-builder

RUN apk add --no-cache \
    bash \
    nodejs-current

# The chown fixes broken uid/gid in ast-types-flow dependency
# (see https://github.com/super-linter/super-linter/issues/3901)
# Npm is not a runtime dependency but we need it to ensure that npm packages
# are installed when we run the test suite. If we decide to remove it, add
# the following command to the RUN instruction below:
# apk del --no-network --purge .node-build-deps
COPY dependencies/package.json dependencies/package-lock.json /
RUN apk add --no-cache --virtual .node-build-deps \
    npm \
    && npm install \
    && npm cache clean --force \
    && chown -R "$(id -u)":"$(id -g)" node_modules \
    && rm -rfv package.json package-lock.json

FROM tflint as tflint-plugins

# Configure TFLint plugin folder
ENV TFLINT_PLUGIN_DIR="/root/.tflint.d/plugins"

# Copy TFlint configuration file because it contains plugin definitions
COPY TEMPLATES/.tflint.hcl /action/lib/.automation/

# Initialize TFLint plugins so we get plugin versions listed when we ask for TFLint version
RUN tflint --init -c /action/lib/.automation/.tflint.hcl

FROM python:3.13.1-alpine3.19 as base_image

LABEL com.github.actions.name="Super-Linter" \
    com.github.actions.description="Super-linter is a ready-to-run collection of linters and code analyzers, to help validate your source code." \
    com.github.actions.icon="code" \
    com.github.actions.color="red" \
    maintainer="@Hanse00, @ferrarimarco, @zkoppert" \
    org.opencontainers.image.authors="Super Linter Contributors: https://github.com/super-linter/super-linter/graphs/contributors" \
    org.opencontainers.image.url="https://github.com/super-linter/super-linter" \
    org.opencontainers.image.source="https://github.com/super-linter/super-linter" \
    org.opencontainers.image.documentation="https://github.com/super-linter/super-linter" \
    org.opencontainers.image.description="A collection of code linters and analyzers."

# https://docs.docker.com/engine/reference/builder/#automatic-platform-args-in-the-global-scope
ARG TARGETARCH

# Install bash first so we can use it
# This is also a super-linter runtime dependency
RUN apk add --no-cache \
    bash

SHELL ["/bin/bash", "-o", "errexit", "-o", "nounset", "-o", "pipefail", "-c"]

# Install super-linter runtime dependencies
# Npm is not a runtime dependency but we need it to ensure that npm packages
# are installed when we run the test suite.
RUN apk add --no-cache \
    ca-certificates \
    coreutils \
    curl \
    file \
    git \
    git-lfs \
    jq \
    libxml2-utils \
    npm \
    nodejs-current \
    openjdk17-jre \
    openssh-client \
    perl \
    php82 \
    php82-ctype \
    php82-curl \
    php82-dom \
    php82-iconv \
    php82-mbstring \
    php82-openssl \
    php82-phar \
    php82-simplexml \
    php82-tokenizer \
    php82-xmlwriter \
    R \
    rakudo \
    ruby \
    zef

# Install Ruby tools
COPY dependencies/Gemfile dependencies/Gemfile.lock /
RUN apk add --no-cache --virtual .ruby-build-deps \
    gcc \
    make \
    musl-dev \
    ruby-bundler \
    ruby-dev \
    ruby-rdoc \
    && bundle install \
    && apk del --no-network --purge .ruby-build-deps \
    && rm -rf Gemfile Gemfile.lock

##############################
# Installs Perl dependencies #
##############################
RUN apk add --no-cache --virtual .perl-build-deps \
    gcc \
    make \
    musl-dev \
    perl-dev \
    && curl --retry 5 --retry-delay 5 -sL https://cpanmin.us/ \
    | perl - -nq --no-wget \
    Perl::Critic \
    Perl::Critic::Bangs \
    Perl::Critic::Community \
    Perl::Critic::Lax \
    Perl::Critic::More \
    Perl::Critic::StricterSubs \
    Perl::Critic::Swift \
    Perl::Critic::Tics \
    && apk del --no-network --purge .perl-build-deps

#################
# Install glibc #
#################
# Source: https://alpine-pkgs.sgerrand.com/sgerrand.rsa.pub
# Store the key here because the above host is sometimes down, and breaks our builds
COPY dependencies/sgerrand.rsa.pub /etc/apk/keys/sgerrand.rsa.pub
ARG GLIBC_VERSION='2.34-r0'
COPY scripts/install-glibc.sh /
RUN --mount=type=secret,id=GITHUB_TOKEN /install-glibc.sh \
    && rm -rf /install-glibc.sh /sgerrand.rsa.pub

##################
# Install chktex #
##################
COPY scripts/install-chktex.sh /
RUN --mount=type=secret,id=GITHUB_TOKEN /install-chktex.sh && rm -rf /install-chktex.sh
# Set work directory back to root because some scripts depend on it
WORKDIR /

#################
# Install Lintr #
#################
COPY scripts/install-lintr.sh scripts/install-r-package-or-fail.R /
RUN /install-lintr.sh && rm -rf /install-lintr.sh /install-r-package-or-fail.R

#################################
# Install luacheck and luarocks #
#################################
COPY scripts/install-lua.sh /
RUN --mount=type=secret,id=GITHUB_TOKEN /install-lua.sh && rm -rf /install-lua.sh

##############################
# Install Phive dependencies #
##############################
COPY dependencies/phive.xml /phive.xml
COPY scripts/install-phive.sh /
RUN /install-phive.sh \
    && rm -rfv /install-phive.sh /phive.xml

##################
# Install ktlint #
##################
COPY scripts/install-ktlint.sh /
COPY dependencies/ktlint /ktlint
RUN --mount=type=secret,id=GITHUB_TOKEN /install-ktlint.sh \
    && rm -rfv /install-ktlint.sh /ktlint

######################
# Install CheckStyle #
######################
COPY scripts/install-checkstyle.sh /
COPY dependencies/checkstyle /checkstyle
RUN --mount=type=secret,id=GITHUB_TOKEN /install-checkstyle.sh \
    && rm -rfv /install-checkstyle.sh /checkstyle

##############################
# Install google-java-format #
##############################
COPY scripts/install-google-java-format.sh /
COPY dependencies/google-java-format /google-java-format
RUN --mount=type=secret,id=GITHUB_TOKEN /install-google-java-format.sh \
    && rm -rfv /install-google-java-format.sh /google-java-format

# Copy Node tools
COPY --from=npm-builder /node_modules /node_modules

######################
# Install shellcheck #
######################
COPY --from=shellcheck /bin/shellcheck /usr/bin/

#####################
# Install Go Linter #
#####################
COPY --from=golang /usr/local/go/go.env /usr/lib/go/
COPY --from=golang /usr/local/go/bin/ /usr/lib/go/bin/
COPY --from=golang /usr/local/go/lib/ /usr/lib/go/lib/
COPY --from=golang /usr/local/go/pkg/ /usr/lib/go/pkg/
COPY --from=golang /usr/local/go/src/ /usr/lib/go/src/
COPY --from=golangci-lint /usr/bin/golangci-lint /usr/bin/

#####################
# Install Terraform #
#####################
COPY --from=terraform /bin/terraform /usr/bin/

##################
# Install TFLint #
##################
# Configure TFLint plugin folder
ENV TFLINT_PLUGIN_DIR="/root/.tflint.d/plugins"
COPY --from=tflint /usr/local/bin/tflint /usr/bin/
COPY --from=tflint-plugins "${TFLINT_PLUGIN_DIR}" "${TFLINT_PLUGIN_DIR}"

#####################
# Install Terrascan #
#####################
COPY --from=terrascan /go/bin/terrascan /usr/bin/

######################
# Install Terragrunt #
######################
COPY --from=terragrunt /usr/local/bin/terragrunt /usr/bin/

######################
# Install protolint #
######################
COPY --from=protolint /usr/local/bin/protolint /usr/bin/

################################
# Install editorconfig-checker #
################################
COPY --from=editorconfig-checker /usr/bin/ec /usr/bin/editorconfig-checker

###############################
# Install hadolint dockerfile #
###############################
COPY --from=dockerfile-lint /bin/hadolint /usr/bin/hadolint

#################
# Install shfmt #
#################
COPY --from=shfmt /bin/shfmt /usr/bin/

####################
# Install GitLeaks #
####################
COPY --from=gitleaks /usr/bin/gitleaks /usr/bin/

####################
# Install scalafmt #
####################
COPY --from=scalafmt /bin/scalafmt /usr/bin/

######################
# Install actionlint #
######################
COPY --from=actionlint /usr/local/bin/actionlint /usr/bin/

######################
# Install kubeconform #
######################
COPY --from=kubeconfrm /kubeconform /usr/bin/

#####################
# Install clj-kondo #
#####################
COPY --from=clj-kondo /bin/clj-kondo /usr/bin/

####################
# Install dart-sdk #
####################
ENV DART_SDK /usr/lib/dart
COPY --from=dart "${DART_SDK}" "${DART_SDK}"
RUN chmod 755 "${DART_SDK}" && chmod 755 "${DART_SDK}/bin"

########################
# Install clang-format #
########################
COPY --from=clang-format /usr/bin/clang-format /usr/bin/

########################
# Install python tools #
########################
COPY --from=python-builder /venvs /venvs

#####################
# Install Bash-Exec #
#####################
COPY --chmod=555 scripts/bash-exec.sh /usr/bin/bash-exec

#########################
# Configure Environment #
#########################
# Set image variant
ENV IMAGE="slim"

ENV PATH="${PATH}:/venvs/ansible-lint/bin"
ENV PATH="${PATH}:/venvs/black/bin"
ENV PATH="${PATH}:/venvs/checkov/bin"
ENV PATH="${PATH}:/venvs/cfn-lint/bin"
ENV PATH="${PATH}:/venvs/cpplint/bin"
ENV PATH="${PATH}:/venvs/flake8/bin"
ENV PATH="${PATH}:/venvs/isort/bin"
ENV PATH="${PATH}:/venvs/mypy/bin"
ENV PATH="${PATH}:/venvs/pylint/bin"
ENV PATH="${PATH}:/venvs/snakefmt/bin"
ENV PATH="${PATH}:/venvs/snakemake/bin"
ENV PATH="${PATH}:/venvs/sqlfluff/bin"
ENV PATH="${PATH}:/venvs/yamllint/bin"
ENV PATH="${PATH}:/venvs/yq/bin"
ENV PATH="${PATH}:/node_modules/.bin"
ENV PATH="${PATH}:/usr/lib/go/bin"
ENV PATH="${PATH}:${DART_SDK}/bin:/root/.pub-cache/bin"

# Initialize Terrascan
# Initialize ChkTeX config file
RUN terrascan init \
    && touch ~/.chktexrc

###################################
# Copy linter configuration files #
###################################
COPY TEMPLATES /action/lib/.automation

#################################
# Copy super-linter executables #
#################################
COPY lib /action/lib

ENTRYPOINT ["/action/lib/linter.sh"]

FROM base_image as slim

# Run to build version file and validate image
RUN ACTIONS_RUNNER_DEBUG=true WRITE_LINTER_VERSIONS_FILE=true IMAGE="${IMAGE}" /action/lib/linter.sh

# Set build metadata here so we don't invalidate the container image cache if we
# change the values of these arguments
ARG BUILD_DATE
ARG BUILD_REVISION
ARG BUILD_VERSION

LABEL org.opencontainers.image.created=$BUILD_DATE \
    org.opencontainers.image.revision=$BUILD_REVISION \
    org.opencontainers.image.version=$BUILD_VERSION

ENV BUILD_DATE=$BUILD_DATE
ENV BUILD_REVISION=$BUILD_REVISION
ENV BUILD_VERSION=$BUILD_VERSION

##############################
# Build the standard variant #
##############################
FROM base_image as standard

# https://docs.docker.com/engine/reference/builder/#automatic-platform-args-in-the-global-scope
ARG TARGETARCH
ARG PWSH_VERSION='latest'
ARG PWSH_DIRECTORY='/usr/lib/microsoft/powershell'
ARG PSSA_VERSION='1.21.0'

ENV ARM_TTK_PSD1="/usr/lib/microsoft/arm-ttk/arm-ttk.psd1"
ENV IMAGE="standard"
ENV PATH="${PATH}:/var/cache/dotnet/tools:/usr/share/dotnet"

# Install super-linter runtime dependencies
RUN apk add --no-cache \
    rust-clippy \
    rustfmt

COPY scripts/clippy.sh /usr/bin/clippy
RUN chmod +x /usr/bin/clippy

#########################
# Install dotenv-linter #
#########################
COPY --from=dotenv-linter /dotenv-linter /usr/bin/

###################################
# Install DotNet and Dependencies #
###################################
COPY scripts/install-dotnet.sh /
RUN /install-dotnet.sh && rm -rf /install-dotnet.sh

#########################################
# Install Powershell + PSScriptAnalyzer #
#########################################
COPY scripts/install-pwsh.sh /
RUN --mount=type=secret,id=GITHUB_TOKEN /install-pwsh.sh && rm -rf /install-pwsh.sh

#############################################################
# Install Azure Resource Manager Template Toolkit (arm-ttk) #
#############################################################
COPY scripts/install-arm-ttk.sh /
RUN --mount=type=secret,id=GITHUB_TOKEN /install-arm-ttk.sh && rm -rf /install-arm-ttk.sh

# Run to build version file and validate image again because we installed more linters
RUN ACTIONS_RUNNER_DEBUG=true WRITE_LINTER_VERSIONS_FILE=true IMAGE="${IMAGE}" /action/lib/linter.sh

# Set build metadata here so we don't invalidate the container image cache if we
# change the values of these arguments
ARG BUILD_DATE
ARG BUILD_REVISION
ARG BUILD_VERSION

LABEL org.opencontainers.image.created=$BUILD_DATE \
    org.opencontainers.image.revision=$BUILD_REVISION \
    org.opencontainers.image.version=$BUILD_VERSION

ENV BUILD_DATE=$BUILD_DATE
ENV BUILD_REVISION=$BUILD_REVISION
ENV BUILD_VERSION=$BUILD_VERSION
