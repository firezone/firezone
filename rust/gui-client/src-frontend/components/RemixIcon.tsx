import React from "react";
import arrowDown from "remixicon/icons/Arrows/arrow-down-s-line.svg";
import home from "remixicon/icons/Buildings/home-line.svg";
import palette from "remixicon/icons/Design/palette-line.svg";
import database from "remixicon/icons/Device/database-2-line.svg";
import certificate from "remixicon/icons/Document/certificate-line.svg";
import equalizer from "remixicon/icons/Media/equalizer-line.svg";
import alert from "remixicon/icons/System/alert-line.svg";
import close from "remixicon/icons/System/close-line.svg";
import deleteBin from "remixicon/icons/System/delete-bin-line.svg";
import information from "remixicon/icons/System/information-line.svg";
import settings from "remixicon/icons/System/settings-3-line.svg";
import shareForward from "remixicon/icons/System/share-forward-line.svg";

const icons = {
  alert,
  "arrow-down": arrowDown,
  certificate,
  close,
  database,
  "delete-bin": deleteBin,
  equalizer,
  home,
  information,
  palette,
  settings,
  "share-forward": shareForward,
} as const;

export type RemixIconName = keyof typeof icons;

interface RemixIconProps {
  className?: string;
  name: RemixIconName;
}

export default function RemixIcon({ className = "", name }: RemixIconProps) {
  const source = `url("${icons[name]}")`;

  return (
    <span
      aria-hidden="true"
      className={`inline-block shrink-0 bg-current align-middle ${className}`}
      style={{
        maskImage: source,
        maskPosition: "center",
        maskRepeat: "no-repeat",
        maskSize: "contain",
        WebkitMaskImage: source,
        WebkitMaskPosition: "center",
        WebkitMaskRepeat: "no-repeat",
        WebkitMaskSize: "contain",
      }}
    />
  );
}
