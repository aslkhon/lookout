#!/bin/sh
# Opens the dev build with made-up agents (see Sources/Lookout/Demo.swift) for README screenshots.
# Hosts, project icons and colors are passed as arguments, so your own settings stay untouched.
set -e
cd "$(dirname "$0")/.."
pkill -x Lookout || true
sleep 1
open -n build/Lookout.app --args -demo YES -remoteHosts "(build-box, gpu-box)" -dashboardShowsDetail NO \
    -projectIcon.webshop 🛒 -projectColor.webshop blue \
    -projectIcon.api-gateway 🚪 -projectColor.api-gateway orange \
    -projectIcon.mobile-app 📱 -projectColor.mobile-app purple \
    -projectIcon.ml-pipeline 🧠 -projectColor.ml-pipeline green \
    -projectIcon.docs 📚
