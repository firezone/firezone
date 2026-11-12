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
      <div className="space-y-3">
        <div className="panel divide-y divide-border">
          <SettingRow label="Reset connlib">
            <Button onClick={resetConnlib} type="button">
              Reset
            </Button>
          </SettingRow>
        </div>

        <div className="flex justify-end border-t border-border pt-3">
          <Button onClick={hide} type="button">
            Hide Developer Settings
          </Button>
        </div>
      </div>
    </div>
  );
}
