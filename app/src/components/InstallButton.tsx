import { useEffect, useState } from "react";
import { canInstall, install, onInstallChange } from "../lib/install";

/** Shows only when the browser offers PWA installation. */
export function InstallButton(props: { className?: string; style?: React.CSSProperties }) {
  const [ok, setOk] = useState(canInstall());
  useEffect(() => onInstallChange(() => setOk(canInstall())), []);
  if (!ok) return null;
  return <button className={props.className ?? "btn ghost"} style={props.style} onClick={() => void install()}>Install app</button>;
}
