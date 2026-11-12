import React from "react";
import Button from "./Button";
import SettingRow from "./SettingRow";

interface Props {
  resetConnlib: () => void;
  hide: () => void;
}

export default function DeveloperSettingsPage({ resetConnlib, hide }: Props) {
  return (
    <div className="page">
      <div className="panel divide-y divide-border">
        <SettingRow label="Reset connlib">
          <Button onClick={resetConnlib} type="button">
            Reset
          </Button>
        </SettingRow>
        <SettingRow label="Hide developer settings">
          <Button onClick={hide} type="button">
            Hide
          </Button>
        </SettingRow>
      </div>
    </div>
  );
}
