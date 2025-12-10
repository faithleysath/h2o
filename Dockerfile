# File: Dockerfile
# ==========================================
# 阶段 1: 构建与压缩 (Builder)
# ==========================================
FROM alpine:3.23 AS builder

# 1. 安装构建依赖
# 重点新增: brotli-static, yaml-static, libuv-static 以替代源码中老旧的 deps
RUN apk add --no-cache \
    build-base cmake git linux-headers pkgconf \
    zlib-dev zlib-static \
    openssl-dev openssl-libs-static \
    libuv-dev libuv-static \
    brotli-dev brotli-static \
    yaml-dev yaml-static \
    perl ca-certificates file upx

# 2. 准备目录结构
RUN mkdir -p /scratch_root/etc/h2o \
    /scratch_root/var/www \
    /scratch_root/tmp \
    /scratch_root/etc/ssl/certs \
    && chmod 1777 /scratch_root/tmp

# 3. 创建运行用户及配置证书
RUN echo "h2o:x:10001:10001:Linux User,,,:/var/www:/sbin/nologin" > /scratch_root/etc/passwd && \
    echo "h2o:x:10001:h2o" > /scratch_root/etc/group && \
    cp /etc/ssl/certs/ca-certificates.crt /scratch_root/etc/ssl/certs/

# 4. 创建默认配置文件
# 开启了 compress: ON (将使用我们链接的系统级 Brotli/Gzip)
RUN echo $'user: h2o\n\
hosts:\n\
  "default":\n\
    listen:\n\
      port: 80\n\
    paths:\n\
      "/":\n\
        file.dir: /var/www\n\
access-log: /dev/stdout\n\
error-log: /dev/stderr\n\
compress: ON' > /scratch_root/etc/h2o/h2o.conf

# 接收构建参数
ARG H2O_VERSION=master

# 5. 拉取源码
WORKDIR /src
# 必须使用 recursive，因为我们需要 deps/quicly 和 deps/picotls (HTTP/3 核心)
# 但我们会通过 CMake 忽略 deps/brotli 和 deps/yaml
RUN git clone --recursive https://github.com/h2o/h2o.git . && \
    echo "🔀 Checking out version: $H2O_VERSION" && \
    if [ "$H2O_VERSION" != "master" ]; then git checkout "$H2O_VERSION"; fi

# 6. CMake 配置 (最关键的一步)
RUN mkdir -p build && cd build && \
    cmake .. \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    \
    # --- 功能开关 ---
    -DWITH_MRUBY=OFF \
    -DWITH_H2O_QUIC=ON \
    # 👆 开启 HTTP/3 (依赖源码自带的 quicly，因为它是新的)
    \
    # --- 链接策略 ---
    -DBUILD_SHARED_LIBS=OFF \
    -DOPENSSL_USE_STATIC_LIBS=TRUE \
    -DCMAKE_EXE_LINKER_FLAGS="-static" \
    \
    # --- 依赖库替换策略 (System Libs vs Bundled) ---
    # 1. 关闭 Bundled 的通用库，防止使用 8 年前的代码
    -DWITH_BUNDLED_SSL=OFF \
    -DWITH_BUNDLED_LIBUV=OFF \
    \
    # 2. 强制指定 OpenSSL (Alpine System)
    -DOPENSSL_SSL_LIBRARY=/usr/lib/libssl.a \
    -DOPENSSL_CRYPTO_LIBRARY=/usr/lib/libcrypto.a \
    -DOPENSSL_INCLUDE_DIR=/usr/include \
    \
    # 3. 强制指定 Libuv (Alpine System)
    -DLIBUV_LIBRARIES=/usr/lib/libuv.a \
    -DLIBUV_INCLUDE_DIR=/usr/include \
    \
    # 4. 强制指定 ZLIB (Alpine System)
    -DZLIB_LIBRARY=/usr/lib/libz.a \
    -DZLIB_INCLUDE_DIR=/usr/include \
    \
    # 5. 强制指定 Brotli (Alpine System - 替代 deps/brotli)
    -DBROTLI_DEC_LIBRARY=/usr/lib/libbrotlidec.a \
    -DBROTLI_ENC_LIBRARY=/usr/lib/libbrotlienc.a \
    -DBROTLI_COMMON_LIBRARY=/usr/lib/libbrotlicommon.a \
    -DBROTLI_INCLUDE_DIR=/usr/include \
    \
    # 6. 强制指定 YAML (Alpine System - 替代 deps/yaml)
    -DYAML_LIBRARY=/usr/lib/libyaml.a \
    -DYAML_INCLUDE_DIR=/usr/include

# 7. 编译
RUN cd build && make -j$(nproc)

# 8. 瘦身与压缩
RUN cd build && \
    strip -s h2o && \
    upx --best --lzma h2o

# 9. 验证构建结果
# 必须看到 "statically linked" 字样
RUN file build/h2o | grep -iE "static(ally|-pie) linked" || exit 1

# ==========================================
# 阶段 2: 最终镜像 (Scratch)
# ==========================================
FROM scratch

# 1. 复制基础系统文件 (/etc/passwd, /etc/ssl 等)
COPY --from=builder /scratch_root /

# 2. 复制二进制文件
COPY --from=builder /src/build/h2o /usr/local/bin/h2o

# 3. 复制资源文件 (H2O 默认的一些 assets)
COPY --from=builder /src/share/h2o /usr/local/share/h2o

# 4. 初始化 Web 根目录
# 确保 /var/www 有正确的权限和内容
COPY --from=builder --chown=10001:10001 /src/share/h2o /var/www

# 5. 暴露端口 (HTTP/1.1, HTTP/2, HTTP/3 QUIC)
EXPOSE 80 443 443/udp

VOLUME /var/www

# 使用 exec 格式启动
CMD ["/usr/local/bin/h2o", "-c", "/etc/h2o/h2o.conf"]