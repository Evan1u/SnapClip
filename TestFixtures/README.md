# 性能测试样本

`performance-4k-mixed.png` 是 PRD 指定的固定 3840×2160 中英混排样本，用于 OCR 和大图响应测试。`performance-4k-mixed.expected.txt` 是期望 OCR 文本。

当前 PNG 的 SHA-256：

```text
c1f617ca057cb90c1264721a6cd8dda5f7291b169ff11ffe1f039ec344d27461
```

源文件为同名 SVG。Quick Look 会先输出正方形缩略图，因此重建后还要中心裁剪：

```sh
qlmanage -t -s 3840 -o . performance-4k-mixed.svg
mv performance-4k-mixed.svg.png performance-4k-mixed.png
sips --cropToHeightWidth 2160 3840 performance-4k-mixed.png
shasum -a 256 performance-4k-mixed.png
```

渲染工具或字体变化会改变像素和哈希；若重建样本，必须人工核对图像、更新固定哈希，并把变更作为测试基线变更审阅。验收记录还需包含 macOS 和 Instruments 版本。
