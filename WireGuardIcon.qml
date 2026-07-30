import QtQuick
import QtQuick.Shapes
import qs.Commons

// The official WireGuard mark, drawn as Shape geometry rather than loaded as
// an image: Qt rasterizes it crisply at any size and the colour comes from
// the theme. The dragon stays a knockout, so whatever is behind the icon
// shows through it.
//
// Path data is the badge, the dragon and its eye from
// wireguard.com/img/wireguard.svg, flattened to absolute moveto/lineto/cubic
// because Qt's PathSvg mis-parses the arcs and shorthand curves in the
// original and renders the dragon's head deformed. The artwork lives in a
// 300.2 x 300.2 box once the wordmark's leading offset is folded in.
//
// This wants room: below roughly 20px the dragon collapses into a blob, which
// is why the bar widget uses the vpn glyph and only the panel header draws
// the real mark.
//
// WireGuard is a registered trademark of Jason A. Donenfeld. This is a
// third-party widget, not an official one.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  readonly property real sourceSize: 300.2
  readonly property real scaleFactor: iconSize / sourceSize

  readonly property string badgePath:
    "M301.28 145.56 C301.28 145.56 308.22 0 148.24 0 C6.76 0 2.34 139.63 2.34 139.63 C2.34 " +
    "139.63 -18.471 300 151.5 300 C314.52 300 301.28 145.56 301.28 145.56 Z"

  readonly property string coilPath:
    "M103.48 94.697 C133.497 76.333 171.846 87.557 186.215 115.173 C188.938 120.407 189.284 " +
    "128.464 187.56 133.955 C181.605 152.911 167.546 163.542 148.248 168.058 C153.937 " +
    "163.187 158.466 157.664 159.907 150.033 C161.425 142.72 159.775 135.105 155.364 129.077 " +
    "C148.338 119.425 135.768 115.594 124.553 119.688 C112.672 124.199 106.164 135.042 " +
    "107.337 148.371 C108.427 160.752 117.821 168.776 135.398 171.824 C132.771 173.214 " +
    "130.748 174.238 128.768 175.341 C120.717 179.752 113.71 185.847 108.224 193.209 C106.44 " +
    "195.617 105.214 195.811 102.497 194.15 C67.159 172.54 64.888 118.306 103.48 94.697 Z"

  readonly property string finPath:
    "M77.031 228.227 C71.354 229.668 65.853 231.801 60.05 233.704 C62.888 214.553 85.315 " +
    "196.916 104.28 198.928 C98.786 206.498 95.578 215.484 95.038 224.821 C88.736 225.982 " +
    "82.797 226.763 77.031 228.226 Z"

  readonly property string bodyPath:
    "M197.821 41.247 C203.431 41.453 209.051 41.368 214.665 41.501 C216.066 41.593 217.459 " +
    "41.787 218.832 42.081 C217.577 44.009 216.16 45.827 214.597 47.515 C212.59 49.385 " +
    "210.322 51.213 207.431 48.371 C206.735 47.687 205.092 47.844 203.882 47.828 C198.3 " +
    "47.755 192.71 47.576 187.136 47.787 C182.299 47.942 177.479 48.434 172.711 49.26 " +
    "C171.817 49.42 170.481 52.391 170.892 53.487 C171.861 56.072 173.275 58.923 175.37 " +
    "60.576 C183.11 66.686 191.342 72.172 199.118 78.24 C206.674 84.137 213.707 90.598 " +
    "217.993 99.493 C223.577 111.083 223.74 123.236 221.331 135.443 C217.311 155.821 206.998 " +
    "172.704 190.299 184.967 C183.571 189.908 175.239 192.713 167.532 196.262 C160.754 " +
    "199.385 153.777 202.074 146.983 205.163 C134.734 210.733 127.85 224.028 129.875 237.851 " +
    "C131.734 250.536 142.862 261.122 155.61 263.307 C170.902 265.929 186.681 255.991 " +
    "190.422 240.447 C194.629 222.969 185.133 207.364 167.357 202.634 C166.575 202.426 " +
    "165.789 202.229 164.156 201.807 C168.911 199.683 173.018 198.169 176.809 196.083 " +
    "C183.423 192.443 189.917 188.589 196.29 184.521 C198.164 183.322 199.177 183.321 " +
    "200.775 184.703 C213 195.273 220.293 208.421 222.338 224.542 C225.723 251.226 213.091 " +
    "275.74 189.266 288.304 C152.406 307.743 107.301 285.618 99.16 244.752 C92.187 209.749 " +
    "116.89 177.998 146.622 171.868 C159.409 169.232 171.102 163.909 180.192 154.061 " +
    "C186.058 147.707 188.901 142.255 189.87 139.795 C191.674 135.185 192.597 130.277 " +
    "192.591 125.326 C192.396 121.043 191.39 116.836 189.625 112.928 C186.521 105.853 174.63 " +
    "94.598 171.686 92.224 L143.686 70.303 C142.699 69.491 141.587 69.55 139.178 69.713 " +
    "C136.317 69.907 129.003 70.312 125.847 69.485 C128.4 67.552 135.361 64.739 138.349 " +
    "62.478 C129.276 56.348 118.919 58.562 109.408 56.731 C111.608 52.636 122.489 46.341 " +
    "128.678 45.64 C128.312 42.184 127.748 38.752 126.991 35.359 C126.613 33.968 125.06 " +
    "32.619 123.704 31.824 C120.418 29.897 116.935 28.307 113.155 26.391 C116.539 24.204 " +
    "120.46 22.991 124.487 22.886 C128.303 22.741 132.12 23.113 135.835 23.991 C142.578 " +
    "25.532 147.959 24.526 153.323 19.943 C149.101 18.243 144.88 16.69 140.785 14.853 " +
    "C136.751 13.014 132.819 10.958 129.006 8.694 C139.628 10.17 149.902 14.153 160.763 " +
    "12.698 C160.856 12.204 160.948 11.71 161.041 11.217 C152.921 9.327 144.802 7.437 " +
    "135.812 5.344 C150.852 3.968 164.854 3.74 178.113 10.199 C181.844 12.016 185.748 13.52 " +
    "189.324 15.596 C191.068 16.608 192.242 18.604 193.673 20.155 C194.81 21.388 195.723 " +
    "23.039 197.119 23.782 C202.419 26.6 208.253 26.711 214.197 26.569 C214.242 25.893 " +
    "214.283 25.258 214.328 24.576 C220.31 26.445 227.043 33.344 227.032 38.382 C217.341 " +
    "38.382 207.658 38.345 197.976 38.436 C196.941 38.446 195.914 39.202 194.883 39.611 " +
    "C195.862 40.182 196.825 41.211 197.825 41.248 Z"

  readonly property string eyePath:
    "M185.32 26.906 C184.923 27.155 184.667 27.576 184.63 28.043 C184.593 28.509 184.779 " +
    "28.966 185.131 29.275 C185.426 29.794 185.917 30.174 186.495 30.328 C187.072 30.483 " +
    "187.688 30.399 188.203 30.096 C189.136 29.626 190.051 29.125 191.178 28.53 C190.27 " +
    "27.755 189.542 27.115 188.792 26.498 C187.474 25.412 186.381 26.094 185.32 26.906 Z"

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  Shape {
    // The wordmark's paths carry a translate(-1.5394); fold it in here so the
    // mark sits flush at 0,0 after scaling.
    x: -1.5394 * root.scaleFactor
    preferredRendererType: Shape.CurveRenderer
    transform: Scale {
      xScale: root.scaleFactor
      yScale: root.scaleFactor
      origin.x: 0
      origin.y: 0
    }

    // One ShapePath for every subpath: winding is what turns the dragon into
    // a hole in the badge rather than a second filled shape.
    ShapePath {
      fillColor: root.color
      strokeWidth: -1
      fillRule: ShapePath.WindingFill

      PathSvg { path: root.badgePath }
      PathSvg { path: root.coilPath }
      PathSvg { path: root.finPath }
      PathSvg { path: root.bodyPath }
      PathSvg { path: root.eyePath }
    }
  }
}
