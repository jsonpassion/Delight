---
name: web-sync
description: 파이프라인 작업(P단계, 버그픽스, 성능 변화)을 마친 뒤 웹앱(web/pipeline.html, web/index.html)을 함께 갱신할 때 사용. 커밋 전에 이 스킬을 따라 웹 문서를 코드와 같은 커밋으로 묶는다. 웹만 따로 갱신할 때도 쓴다.
---

# 웹앱 동기화

코드가 바뀌면 웹 문서도 같은 커밋에서 바뀐다. **코드와 문서가 다른 커밋이면 어긋난 채 배포된다.**

## 갱신 대상

| 파일 | 언제 |
|---|---|
| `web/pipeline.html` | 새 단계 완료, 버그 발견·수정, 실측 수치 변화, 설계 결정 |
| `web/index.html` | 측정값 표(median/fps)가 바뀌었을 때만 |
| `README.md` | 진행 상황 체크리스트 |

## pipeline.html 작성 규칙

1. **인사이트 단위로 쓴다** — "무엇을 했다"가 아니라 "무엇이 왜 그랬고 어떻게 확인했다"
2. 버그는 `.bugs > .bug` 카드: 증상(sym) → 원인 → 수정(fix). **크래시 스택·에러 문자열 원문**을 sym에
3. 실측 수치는 반드시 조건과 함께 (기기, 해상도, 반복 횟수, ON/OFF 조건)
4. 새 섹션은 기존 번호 체계(`06-1`, `06-2`…)를 따르고 **목차(nav.toc)에도 추가**
5. 코드 스니펫은 고치기 전/후를 대비 (`✗`/`✓`, `.hl` 하이라이트)
6. 다크/라이트 토큰만 사용 — 색을 직접 쓰지 않는다

## 검증 (필수 — 빠뜨리면 배포가 깨진 채 나간다)

```bash
python3 Tools/check_html.py          # 태그 균형 + 목차-섹션 대응
```

## 배포 확인

푸시 후 HEAD 커밋의 배포가 성공했는지 확인한다. 직전 배포의 success를 보고 착각하기 쉽다:

```bash
HEAD=$(git rev-parse --short HEAD)
gh run list --repo jsonpassion/Delight --workflow pages.yml --limit 1 \
  --json headSha,status,conclusion \
  --jq '.[0].headSha[0:7]+" "+.[0].status+"/"+(.[0].conclusion // "-")'
# 출력이 "$HEAD completed/success" 여야 한다
curl -sS https://jsonpassion.github.io/Delight/pipeline.html | grep -c "<새 섹션 제목>"
```
