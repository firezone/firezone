import {
  TextInputProps,
  Tooltip,
  TextInput,
  ToggleSwitch,
  ToggleSwitchProps,
} from "flowbite-react";
import React, { PropsWithChildren } from "react";

export function ManagedTextInput(props: TextInputProps & { managed: boolean }) {
  const { managed, ...inputProps } = props;

  if (managed) {
    return (
      <ManagedTooltip>
        <TextInput {...inputProps} disabled={true} />
      </ManagedTooltip>
    );
  } else {
    return <TextInput {...inputProps} />;
  }
}

export function ManagedToggleSwitch(
  props: ToggleSwitchProps & { managed: boolean },
) {
  const { managed, ...toggleSwitchProps } = props;

  if (managed) {
    return (
      <ManagedTooltip>
        <ToggleSwitch {...toggleSwitchProps} disabled={true} />
      </ManagedTooltip>
    );
  } else {
    return <ToggleSwitch {...toggleSwitchProps} />;
  }
}

function ManagedTooltip(props: PropsWithChildren) {
  const { children } = props;

  return (
    <Tooltip
      content="This setting is managed by your organisation."
      clearTheme={{ target: true }}
    >
      {children}
    </Tooltip>
  );
}
