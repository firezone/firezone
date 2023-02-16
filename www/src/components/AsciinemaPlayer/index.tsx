import React, { useEffect, useRef } from 'react';
import BrowserOnly from '@docusaurus/BrowserOnly';

type AsciinemaPlayerProps = {
    src: string;
    // START asciinemaOptions
    cols: string;
    rows: string;
    autoPlay: boolean
    preload: boolean;
    loop: boolean | number;
    startAt: number | string;
    speed: number;
    idleTimeLimit: number;
    theme: string;
    poster: string;
    fit: string;
    fontSize: string;
    // END asciinemaOptions
};

const AsciinemaPlayer: React.FC<AsciinemaPlayerProps> = ({
    src,
    ...asciinemaOptions
}) => {
    const ref = useRef<HTMLDivElement>(null);

    return (
      <BrowserOnly fallback={<div>Loading...</div>}>
          {() => {
              const AsciinemaPlayerLibrary = require('asciinema-player');

              useEffect(() => {
                  const currentRef = ref.current;
                  AsciinemaPlayerLibrary.create(src, currentRef, asciinemaOptions);
              }, [src]);

              return <div ref={ref} />
          }}
      </BrowserOnly>
    );
};

export default AsciinemaPlayer;
