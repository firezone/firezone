declare module "asciinema-player" {
  export interface AsciinemaOptions {
    cols?: string;
    rows?: string;
    autoPlay?: boolean;
    preload?: boolean;
    loop?: boolean | number;
    startAt?: number | string;
    speed?: number;
    idleTimeLimit?: number;
    theme?: string;
    poster?: string;
    fit?: string;
    fontSize?: string;
  }

  export function create(
    src: string,
    element: HTMLElement,
    options?: AsciinemaOptions
  ): void;
}
