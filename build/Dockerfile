FROM archlinux:base-devel

RUN sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf \
    && pacman -Syu --noconfirm --needed git \
    && useradd -m -U -s /bin/bash builder \
    && pacman -Scc --noconfirm

COPY makepkg.conf.d/gilgamesh.conf /etc/makepkg.conf.d/gilgamesh.conf

USER builder
WORKDIR /work
