# Execution Lock

## canvas
- viewBox: 0 0 1280 720
- format: PPT 16:9

## colors
- bg: #0F1419
- bg_secondary: #1A2332
- primary: #1565C0
- accent: #FF9800
- secondary_accent: #42A5F5
- text: #E8EAED
- text_secondary: #9AA0A6
- text_tertiary: #6B7280
- border: #2D3748
- success: #4CAF50
- warning: #F44336

## typography
- font_family: "Microsoft YaHei", "PingFang SC", Arial, sans-serif
- title_family: SimHei, "Microsoft YaHei", Arial, sans-serif
- body_family: "Microsoft YaHei", "PingFang SC", Arial, sans-serif
- emphasis_family: SimHei, "Microsoft YaHei", Arial, sans-serif
- code_family: Consolas, "Courier New", monospace
- body: 20
- title: 36
- subtitle: 26
- annotation: 14
- footnote: 11
- cover_title: 60
- chapter_title: 48
- hero_number: 56

## icons
- library: tabler-filled
- inventory: world, cloud, cloud-computing, database, alert-hexagon, circle-check, circle-x, bolt, building-bridge-2, clock-hour-1, shield-check, code-circle, eye, messages, trend-up, bug, lock, flag-3, user

## images
- case-1-01-investigation-list: images/case-1-01-investigation-list.png | no-crop
- case-1-02-investigation-timeline: images/case-1-02-investigation-timeline.png | no-crop
- case-1-03-rca-report: images/case-1-03-rca-report.png | no-crop
- case-1-04-mitigation-plan: images/case-1-04-mitigation-plan.png | no-crop
- case-1-05-slack-thread: images/case-1-05-slack-thread.png | no-crop
- case-1-06-cloudwatch-alarm: images/case-1-06-cloudwatch-alarm.png | no-crop
- case-1-07-eks-pod-failed: images/case-1-07-eks-pod-failed.png | no-crop
- case-2-01-investigation-list: images/case-2-01-investigation-list.png | no-crop
- case-2-02-investigation-timeline: images/case-2-02-investigation-timeline.png | no-crop
- case-2-03-rca-time-anchor: images/case-2-03-rca-time-anchor.png | no-crop
- case-2-04-cloudwatch-p99: images/case-2-04-cloudwatch-p99.png | no-crop
- case-2-04-rca-full: images/case-2-04-rca-full.png | no-crop
- case-2-05-mcp-server-log: images/case-2-05-mcp-server-log.png | no-crop
- case-3-01-investigation-list: images/case-3-01-investigation-list.png | no-crop
- case-3-02-investigation-timeline: images/case-3-02-investigation-timeline.png | no-crop
- case-3-03-rca-summary: images/case-3-03-rca-summary.png | no-crop
- case-3-05-mcp-server-log: images/case-3-05-mcp-server-log.png | no-crop

## page_rhythm
- P01: anchor
- P02: dense
- P03: breathing
- P04: dense
- P05: dense
- P06: dense
- P07: breathing
- P08: dense
- P09: dense
- P10: breathing
- P11: dense
- P12: dense
- P13: breathing
- P14: dense
- P15: dense
- P16: breathing
- P17: dense
- P18: dense
- P19: dense
- P20: anchor

## page_charts
- P06: hub_spoke
- P08: pyramid_chart
- P11: process_flow
- P15: sankey_chart

## forbidden
- Mixing icon libraries
- rgba()
- `<style>`, `class`, `<foreignObject>`, `textPath`, `@font-face`, `<animate*>`, `<script>`, `<iframe>`, `<symbol>`+`<use>`
- `<g opacity>` (set opacity per child)
- HTML named entities in text — write raw Unicode; escape XML reserved as `&amp; &lt; &gt; &quot; &apos;`
