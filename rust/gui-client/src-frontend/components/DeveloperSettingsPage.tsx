import React, { useId } from "react";
import Button from "./Button";
import { ManagedToggleSwitch } from "./ManagedInput";
import SettingRow from "./SettingRow";

interface Props {
  resetConnlib: () => void;
  forceRelayedConnections: boolean;
  setForceRelayedConnections: (enabled: boolean) => void;
  hide: () => void;
}

export default function DeveloperSettingsPage({
  resetConnlib,
  forceRelayedConnections,
  setForceRelayedConnections,
  hide,
}: Props) {
  const forceRelayedConnectionsInputId = useId();

  return (
    <div className="page">
      <div className="space-y-3">
        <div className="panel divide-y divide-border">
          <SettingRow label="Reset connlib">
            <Button onClick={resetConnlib} type="button">
              Reset
            </Button>
          </SettingRow>
          <SettingRow
            inputId={forceRelayedConnectionsInputId}
            label="Force relayed connections"
          >
            <ManagedToggleSwitch
              checked={forceRelayedConnections}
              id={forceRelayedConnectionsInputId}
              managed={false}
              onChange={setForceRelayedConnections}
            />
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
