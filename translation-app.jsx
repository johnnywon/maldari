import { useState, useEffect, useRef } from "react";

const TRANSCRIPTS = [
  { id: "t1", date: "2026 March 27, Thursday", time: "14:15", label: "PULSEAD PRODUCT SYNC", duration: "34 MIN", lines: 28 },
  { id: "t2", date: "2026 March 26, Wednesday", time: "10:00", label: "KOREA REVENUE REVIEW", duration: "51 MIN", lines: 47 },
  { id: "t3", date: "2026 March 24, Monday", time: "09:30", label: "ENGINEERING STANDUP", duration: "18 MIN", lines: 14 },
  { id: "t4", date: "2026 March 21, Friday", time: "16:00", label: "SERIES A PREP CALL", duration: "42 MIN", lines: 36 },
  { id: "t5", date: "2026 March 19, Wednesday", time: "11:00", label: "AMC DEMO WALKTHROUGH", duration: "27 MIN", lines: 22 },
  { id: "t6", date: "2026 March 17, Monday", time: "15:30", label: "GTM STRATEGY SESSION", duration: "38 MIN", lines: 31 },
];

const LINES = [
  { ts: "14:15:03", ko: "오늘 미팅에서 AMC 파이프라인 데모를 확정해야 합니다", en: "We need to finalize the AMC pipeline demo in today's meeting" },
  { ts: "14:15:18", ko: "한국 쪽 클라이언트 세 곳이 이번 분기에 계약 마무리 단계에 있습니다", en: "Three clients on the Korea side are in the final stages of closing contracts this quarter" },
  { ts: "14:15:34", ko: "시리즈 A 미팅 전에 데모가 준비되어야 합니다", en: "The demo needs to be ready before the Series A meetings" },
  { ts: "14:15:52", ko: "엔지니어링 팀은 목요일까지 준비할 수 있습니다", en: "Engineering team can have it ready by Thursday" },
  { ts: "14:16:11", ko: "서울의 엔터프라이즈 클라이언트가 AMC 데이터용 커스텀 대시보드를 원합니다", en: "The enterprise client in Seoul wants a custom dashboard for their AMC data" },
  { ts: "14:16:30", ko: "지금은 핵심 기능에 집중해야 합니다", en: "Right now we need to focus on core features" },
  { ts: "14:16:48", ko: "에이전트 실행 레이어가 가장 중요합니다", en: "The agent execution layer is the most important part" },
  { ts: "14:17:05", ko: "미국 시장 진출 전략도 같이 이야기해야 하지 않나요?", en: "Shouldn't we also discuss the US market entry strategy?" },
];

const SOURCES = [
  "SYSTEM AUDIO // ZOOM",
  "SYSTEM AUDIO // GOOGLE MEET",
  "BUILT-IN MICROPHONE",
  "EXTERNAL MICROPHONE",
  "BLACKHOLE 2CH",
];

const LIME = "#BBFF00";
const LD = "rgba(187,255,0,";
const CYAN = "#5CE0D8";
const CD = "rgba(92,224,216,";
const GLASS = "rgba(10,10,18,.76)";
const GLASS_HD = "rgba(14,14,24,.8)";
const TXT = "#f4f5f7";
const TXT_META = "rgba(244,245,247,.62)";
const TXT_DIM = "rgba(244,245,247,.38)";
const BORDER = "rgba(255,255,255,.05)";
const BRD_HI = `${LD}.14)`;
const MONO = "'SF Mono','Fira Code','JetBrains Mono','Menlo',monospace";
const SANS = "'SF Pro Display','Helvetica Neue',-apple-system,sans-serif";

function DriveBtn() {
  return (
    <a className="tl-dv" href="https://drive.google.com" target="_blank" rel="noopener noreferrer"
      onClick={e => e.stopPropagation()}>
      <svg width="16" height="14" viewBox="0 0 20 17" fill="none">
        <path d="M6.5 0.5L0.5 10.5H6.5L12.5 0.5H6.5Z" fill={`${CD}.25)`} stroke={CYAN} strokeWidth=".7"/>
        <path d="M12.5 0.5L6.5 10.5H12.5L19 10.5L12.5 0.5Z" fill={`${LD}.18)`} stroke={LIME} strokeWidth=".7"/>
        <path d="M0.5 10.5L3.5 16H16L19 10.5H0.5Z" fill={`${CD}.15)`} stroke={`${CD}.5)`} strokeWidth=".7"/>
      </svg>
    </a>
  );
}

export default function App() {
  const [view, setView] = useState("live");
  const [src, setSrc] = useState(0);
  const [picker, setPicker] = useState(false);
  const [on, setOn] = useState(true);
  const [lines, setLines] = useState([]);
  const ref = useRef(null);
  const pkRef = useRef(null);
  const idx = useRef(0);

  useEffect(() => {
    if (view !== "live") return;
    setLines([]);
    idx.current = 0;
    const iv = setInterval(() => {
      if (idx.current >= LINES.length) { clearInterval(iv); return; }
      const line = LINES[idx.current];
      idx.current++;
      setLines(p => [...p, line]);
    }, 2400);
    return () => clearInterval(iv);
  }, [view]);

  useEffect(() => {
    if (ref.current) ref.current.scrollTop = ref.current.scrollHeight;
  }, [lines]);

  useEffect(() => {
    const h = e => { if (pkRef.current && !pkRef.current.contains(e.target)) setPicker(false); };
    document.addEventListener("mousedown", h);
    return () => document.removeEventListener("mousedown", h);
  }, []);

  const tabActive = (a) => ({
    fontFamily: MONO, fontSize: 10, letterSpacing: ".08em", fontWeight: 500,
    padding: "0 14px", height: "100%", display: "flex", alignItems: "center",
    border: "none", background: a ? `${LD}.04)` : "none", cursor: "pointer",
    color: a ? LIME : TXT_DIM, transition: "all .15s",
    borderBottom: a ? `1.5px solid ${LIME}` : "1.5px solid transparent",
  });

  return (
    <div style={{ fontFamily: SANS, width: "100%", maxWidth: 560, margin: "0 auto", WebkitFontSmoothing: "antialiased" }}>
      <style>{`
        @keyframes fadeIn{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:translateY(0)}}
        @keyframes pulse3{0%,100%{opacity:.15}50%{opacity:1}}
        @keyframes barY{0%,100%{transform:scaleY(.2)}50%{transform:scaleY(1)}}
        @keyframes glow{0%,100%{box-shadow:0 0 6px ${LD}.1)}50%{box-shadow:0 0 18px ${LD}.25)}}
        .tl-ln{animation:fadeIn .35s ease-out both}
        .tl-s::-webkit-scrollbar{width:3px}
        .tl-s::-webkit-scrollbar-track{background:transparent}
        .tl-s::-webkit-scrollbar-thumb{background:rgba(255,255,255,.06);border-radius:2px}
        .tl-s::-webkit-scrollbar-thumb:hover{background:rgba(255,255,255,.12)}
        .tl-hi{cursor:pointer;transition:background .12s}
        .tl-hi:hover{background:rgba(255,255,255,.02)}
        .tl-si{padding:9px 14px;font-size:11px;cursor:pointer;border-radius:3px;transition:all .1s;letter-spacing:.04em;color:rgba(244,245,247,.5)}
        .tl-si:hover{background:${LD}.05);color:${TXT}}
        .tl-dv{display:flex;align-items:center;justify-content:center;width:34px;height:34px;border-radius:3px;border:.5px solid ${CD}.12);background:${CD}.03);cursor:pointer;transition:all .15s;text-decoration:none;flex-shrink:0}
        .tl-dv:hover{background:${CD}.08);border-color:${CD}.28)}
      `}</style>

      {/* Glass container */}
      <div style={{
        borderRadius: 10,
        border: `.5px solid ${BRD_HI}`,
        overflow: "hidden",
        position: "relative",
        background: GLASS,
        backdropFilter: "blur(52px) saturate(1.5) brightness(0.95)",
        WebkitBackdropFilter: "blur(52px) saturate(1.5) brightness(0.95)",
        boxShadow: `0 0 0 .5px rgba(255,255,255,.03) inset, 0 20px 70px rgba(0,0,0,.4), 0 1px 2px rgba(0,0,0,.2)`,
      }}>
        {/* Scanlines */}
        <div style={{
          position: "absolute", inset: 0, pointerEvents: "none", zIndex: 50,
          background: `repeating-linear-gradient(0deg,transparent,transparent 2px,rgba(255,255,255,.006) 2px,rgba(255,255,255,.006) 4px)`,
        }}/>

        {/* Top gradient accent */}
        <div style={{ height: 2, background: `linear-gradient(90deg,${LIME},${CYAN})`, opacity: .4 }}/>

        {/* Corner marks */}
        {["top-left","top-right","bottom-left","bottom-right"].map(pos => {
          const [v, h] = pos.split("-");
          return (
            <div key={pos} style={{ position: "absolute", [v]: 0, [h]: 0, zIndex: 51 }}>
              <div style={{ position: "absolute", [v]: 0, [h]: 0, width: 22, height: 1, background: LIME, opacity: .12 }}/>
              <div style={{ position: "absolute", [v]: 0, [h]: 0, width: 1, height: 22, background: LIME, opacity: .12 }}/>
            </div>
          );
        })}

        {/* Header */}
        <div style={{
          display: "flex", alignItems: "stretch",
          background: GLASS_HD,
          backdropFilter: "blur(20px)",
          WebkitBackdropFilter: "blur(20px)",
          borderBottom: `.5px solid ${BORDER}`,
          position: "relative", zIndex: 10, height: 46,
        }}>
          <div ref={pkRef} style={{ position: "relative", display: "flex", alignItems: "center", padding: "0 14px", borderRight: `.5px solid ${BORDER}` }}>
            <button onClick={() => setPicker(!picker)} style={{
              background: "none", border: "none", padding: 0,
              fontSize: 11, color: LIME, cursor: "pointer",
              display: "flex", alignItems: "center", gap: 7,
              fontFamily: MONO, letterSpacing: ".04em", whiteSpace: "nowrap",
            }}>
              <svg width="11" height="11" viewBox="0 0 16 16" fill="none">
                <rect x="5.5" y="1" width="5" height="9" rx="2.5" stroke={LIME} strokeWidth="1.2"/>
                <path d="M3 7.5C3 10.26 5.24 12.5 8 12.5C10.76 12.5 13 10.26 13 7.5" stroke={LIME} strokeWidth="1.2" strokeLinecap="round"/>
                <line x1="8" y1="12.5" x2="8" y2="15" stroke={LIME} strokeWidth="1.2" strokeLinecap="round"/>
              </svg>
              <span style={{ maxWidth: 170, overflow: "hidden", textOverflow: "ellipsis" }}>{SOURCES[src]}</span>
              <svg width="7" height="4" viewBox="0 0 7 4" fill="none">
                <path d="M1 .5L3.5 3L6 .5" stroke={LIME} strokeWidth="1" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            </button>
            {picker && (
              <div style={{
                position: "absolute", top: "calc(100% + 4px)", left: 8, minWidth: 260,
                background: "rgba(16,16,26,.92)",
                backdropFilter: "blur(36px)", WebkitBackdropFilter: "blur(36px)",
                borderRadius: 6, border: `.5px solid ${BRD_HI}`,
                boxShadow: "0 14px 50px rgba(0,0,0,.7)", padding: 4, zIndex: 200,
              }}>
                {SOURCES.map((s, i) => (
                  <div key={i} className="tl-si"
                    style={{ fontFamily: MONO, ...(i === src ? { color: LIME, background: `${LD}.05)` } : {}) }}
                    onClick={() => { setSrc(i); setPicker(false); }}>{s}</div>
                ))}
              </div>
            )}
          </div>

          <button onClick={() => setView("live")} style={tabActive(view === "live")}>LIVE</button>
          <button onClick={() => setView("history")} style={tabActive(view === "history")}>TRANSCRIPTS</button>

          <div style={{ flex: 1 }}/>

          {on && view === "live" && lines.length > 0 && (
            <div style={{ display: "flex", alignItems: "center", gap: 5, padding: "0 10px" }}>
              <div style={{ width: 4, height: 4, borderRadius: "50%", background: LIME, boxShadow: `0 0 6px ${LD}.4)` }}/>
              <span style={{ fontFamily: MONO, fontSize: 9, color: LIME, letterSpacing: ".05em", opacity: .5 }}>
                {lines.length}
              </span>
            </div>
          )}

          <div style={{ display: "flex", alignItems: "center", padding: "0 10px", borderLeft: `.5px solid ${BORDER}` }}>
            <button onClick={() => setOn(!on)} style={{
              width: 34, height: 34, borderRadius: 3, border: "none",
              background: on ? LIME : "rgba(255,255,255,.06)",
              cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "center",
              transition: "all .2s",
              animation: on ? "glow 2.5s ease-in-out infinite" : "none",
            }}>
              {on ? (
                <div style={{ display: "flex", gap: 2, alignItems: "center", height: 14 }}>
                  {[8, 14, 6, 12, 4].map((h, i) => (
                    <div key={i} style={{
                      width: 2, height: h, background: "rgba(10,10,18,.9)", borderRadius: 1,
                      animation: `barY ${.4 + i * .12}s ease-in-out infinite`,
                      animationDelay: `${i * .08}s`, transformOrigin: "center",
                    }}/>
                  ))}
                </div>
              ) : (
                <svg width="13" height="13" viewBox="0 0 16 16" fill="none">
                  <rect x="5.5" y="1" width="5" height="9" rx="2.5" stroke={TXT_META} strokeWidth="1.3"/>
                  <line x1="2" y1="2" x2="14" y2="14" stroke={TXT_META} strokeWidth="1.3" strokeLinecap="round"/>
                </svg>
              )}
            </button>
          </div>
        </div>

        {/* Live */}
        {view === "live" ? (
          <div ref={ref} className="tl-s"
            style={{ height: 560, overflowY: "auto", padding: "20px 22px 32px" }}>

            {lines.length === 0 && (
              <div style={{
                height: "100%", display: "flex", flexDirection: "column",
                alignItems: "center", justifyContent: "center", gap: 16,
              }}>
                <div style={{ display: "flex", gap: 4, alignItems: "center" }}>
                  {[0, 1, 2, 3, 4].map(i => (
                    <div key={i} style={{
                      width: 2, height: 20, background: CYAN, borderRadius: 1, opacity: .2,
                      animation: `barY ${.5 + i * .1}s ease-in-out infinite`,
                      animationDelay: `${i * .1}s`, transformOrigin: "center",
                    }}/>
                  ))}
                </div>
                <span style={{ fontFamily: MONO, fontSize: 11, color: TXT_DIM, letterSpacing: ".08em" }}>
                  AWAITING SIGNAL...
                </span>
              </div>
            )}

            {lines.map((l, i) => (
              <div key={i} className="tl-ln" style={{
                marginBottom: 4, padding: "16px 0 22px",
                borderBottom: i < lines.length - 1 ? `.5px solid ${BORDER}` : "none",
              }}>
                <div style={{
                  fontFamily: SANS, fontSize: 18, color: CYAN,
                  lineHeight: 1.7, marginBottom: 10, fontWeight: 400, opacity: .85,
                }}>
                  {l.ko}
                </div>
                <div style={{
                  fontFamily: SANS, fontSize: 20, color: TXT,
                  lineHeight: 1.5, fontWeight: 400, letterSpacing: "-.012em",
                }}>
                  {l.en}
                </div>
                <div style={{ display: "flex", justifyContent: "flex-end", marginTop: 12, alignItems: "center", gap: 8 }}>
                  <div style={{ flex: 1, height: .5, background: `linear-gradient(90deg,transparent,rgba(255,255,255,.025),transparent)` }}/>
                  <span style={{
                    fontFamily: MONO, fontSize: 11, color: `${LD}.35)`,
                    letterSpacing: ".06em", fontWeight: 500,
                  }}>
                    {l.ts}
                  </span>
                </div>
              </div>
            ))}

            {on && lines.length > 0 && lines.length < LINES.length && (
              <div style={{ display: "flex", gap: 5, padding: "14px 0", alignItems: "center" }}>
                {[0, 1, 2].map(d => (
                  <div key={d} style={{
                    width: 3, height: 3, borderRadius: "50%", background: CYAN,
                    animation: `pulse3 1.2s ease-in-out infinite`,
                    animationDelay: `${d * .25}s`,
                  }}/>
                ))}
              </div>
            )}
          </div>
        ) : (
          /* Transcripts */
          <div className="tl-s" style={{ height: 560, overflowY: "auto" }}>
            {TRANSCRIPTS.map(t => (
              <div key={t.id} className="tl-hi" style={{ borderBottom: `.5px solid ${BORDER}` }}>
                <div style={{ padding: "18px 22px", display: "flex", alignItems: "flex-start", gap: 14 }}>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 8 }}>
                      <span style={{ fontFamily: SANS, fontSize: 16, fontWeight: 500, color: TXT, letterSpacing: "-.01em" }}>
                        {t.label}
                      </span>
                      <span style={{
                        fontFamily: MONO, fontSize: 9, letterSpacing: ".04em",
                        color: "rgba(10,10,18,.9)", background: LIME, padding: "2px 9px", borderRadius: 2, fontWeight: 600,
                      }}>
                        {t.duration}
                      </span>
                    </div>
                    <div style={{ fontFamily: MONO, fontSize: 11, letterSpacing: ".02em" }}>
                      <span style={{ color: TXT_META, fontWeight: 500 }}>{t.date}</span>
                      <span style={{ color: "rgba(255,255,255,.08)", margin: "0 10px" }}>//</span>
                      <span style={{ color: TXT_META, fontWeight: 500 }}>{t.time}</span>
                      <span style={{ color: "rgba(255,255,255,.08)", margin: "0 10px" }}>//</span>
                      <span style={{ color: CYAN, opacity: .55, fontWeight: 500 }}>{t.lines} LINES</span>
                    </div>
                  </div>
                  <DriveBtn/>
                </div>
              </div>
            ))}
          </div>
        )}

        {/* Bottom accent */}
        <div style={{ height: 1, background: `linear-gradient(90deg,${LIME},${CYAN})`, opacity: .2 }}/>
      </div>
    </div>
  );
}
