import { useCallback, useEffect, useRef, useState } from "react";

const GAME_URL = "/game/index.html";

function useWebgl2Support(): boolean | null {
  const [supported, setSupported] = useState<boolean | null>(null);
  useEffect(() => {
    try {
      const canvas = document.createElement("canvas");
      setSupported(Boolean(canvas.getContext("webgl2")));
    } catch {
      setSupported(false);
    }
  }, []);
  return supported;
}

function EnterFullscreenIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5" />
    </svg>
  );
}

function ExitFullscreenIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M9 4v5H4M15 4v5h5M9 20v-5H4M15 20v-5h5" />
    </svg>
  );
}

function CloseIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M6 6l12 12M18 6L6 18" />
    </svg>
  );
}

export default function App() {
  const [launched, setLaunched] = useState(false);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const shellRef = useRef<HTMLDivElement>(null);
  const frameRef = useRef<HTMLIFrameElement>(null);
  const webgl2 = useWebgl2Support();

  const playable = webgl2 !== false;

  useEffect(() => {
    const onChange = () => setIsFullscreen(Boolean(document.fullscreenElement));
    document.addEventListener("fullscreenchange", onChange);
    return () => document.removeEventListener("fullscreenchange", onChange);
  }, []);

  useEffect(() => {
    if (!launched && document.fullscreenElement) {
      void document.exitFullscreen();
    }
  }, [launched]);

  const launch = useCallback(() => {
    setLaunched(true);
    shellRef.current?.requestFullscreen();
  }, []);

  const exit = useCallback(() => setLaunched(false), []);

  const toggleFullscreen = useCallback(() => {
    const shell = shellRef.current;
    if (!shell) return;
    if (document.fullscreenElement) {
      void document.exitFullscreen();
    } else {
      void shell.requestFullscreen();
    }
  }, []);

  const onFrameLoad = useCallback(() => {
    frameRef.current?.focus();
  }, []);

  if (!launched) {
    return (
      <main className="start">
        <h1>
          Chrome Rift <span>RS</span>
        </h1>
        <button className="play" onClick={launch} disabled={!playable}>
          {playable ? "Play" : "WebGL2 required"}
        </button>
        {webgl2 === false && (
          <p className="notice">
            This browser does not expose WebGL2. Try a recent Chrome, Edge,
            Firefox or Safari with hardware acceleration on.
          </p>
        )}
      </main>
    );
  }

  return (
    <div className="shell" ref={shellRef}>
      <iframe
        ref={frameRef}
        className="frame"
        src={GAME_URL}
        title="Chrome Rift RS"
        allow="autoplay; fullscreen; gamepad"
        tabIndex={0}
        onLoad={onFrameLoad}
      />
      <div className="corner-tools">
        <button
          className="icon-btn"
          onClick={toggleFullscreen}
          title={isFullscreen ? "Exit fullscreen" : "Enter fullscreen"}
          aria-label={isFullscreen ? "Exit fullscreen" : "Enter fullscreen"}
        >
          {isFullscreen ? <ExitFullscreenIcon /> : <EnterFullscreenIcon />}
        </button>
        <button
          className="icon-btn"
          onClick={exit}
          title="Exit game"
          aria-label="Exit game"
        >
          <CloseIcon />
        </button>
      </div>
    </div>
  );
}
