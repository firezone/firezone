import Image from "next/image";
import Link from "next/link";
import Marquee from "react-fast-marquee";

export function CustomerLogosGrayscale() {
  return (
    <div className="lg:fade-side overflow-hidden flex justify-center w-full">
      <div className="animate-left inline-block whitespace-nowrap">
        <div className="inline-flex">
          <Link
            className="h-16 mr-20 place-content-center"
            href="https://corrdyn.com"
          >
            <Image
              alt="corrdyn logo"
              src="/images/logos/cust-logo-corrdyn-gray.svg"
              width={125}
              height={125}
              priority
            />
          </Link>
          <Link
            className="h-16 mr-20 place-content-center"
            href="https://square1.io"
          >
            <Image
              alt="square1 logo"
              src="/images/logos/cust-logo-square1-gray.svg"
              width={100}
              height={100}
              priority
            />
          </Link>
          <Link
            className="h-16 mr-20 place-content-center"
            href="https://wolfram.com"
          >
            <Image
              alt="wolfram logo"
              src="/images/logos/cust-logo-wolfram-gray.svg"
              width={60}
              height={75}
              priority
            />
          </Link>
          <Link
            className="h-16 mr-20 place-content-center"
            href="https://teracloud.com"
          >
            <Image
              alt="teracloud logo"
              src="/images/logos/cust-logo-teracloud-gray.svg"
              width={125}
              height={125}
              className="  "
              priority
            />
          </Link>
          <Link
            className="h-16 mr-20 place-content-center"
            href="https://double11.co.uk"
          >
            <Image
              alt="double11 logo"
              src="/images/logos/cust-logo-double11-gray.svg"
              width={50}
              height={50}
              priority
            />
          </Link>
        </div>
        <div className="inline-flex">
          <Link
            className="h-16 mr-20 place-content-center"
            href="https://corrdyn.com"
          >
            <Image
              alt="corrdyn logo"
              src="/images/logos/cust-logo-corrdyn-gray.svg"
              width={125}
              height={125}
            />
          </Link>
          <Link
            className="h-16 mr-20 place-content-center"
            href="https://square1.io"
          >
            <Image
              alt="square1 logo"
              src="/images/logos/cust-logo-square1-gray.svg"
              width={100}
              height={100}
            />
          </Link>
          <Link
            className="h-16 mr-20 place-content-center"
            href="https://wolfram.com"
          >
            <Image
              alt="wolfram logo"
              src="/images/logos/cust-logo-wolfram-gray.svg"
              width={60}
              height={75}
            />
          </Link>
          <Link
            className="h-16 mr-20 place-content-center"
            href="https://teracloud.com"
          >
            <Image
              alt="teracloud logo"
              src="/images/logos/cust-logo-teracloud-gray.svg"
              width={125}
              height={125}
            />
          </Link>
          <Link
            className="h-16 mr-20 place-content-center"
            href="https://double11.co.uk"
          >
            <Image
              alt="double11 logo"
              src="/images/logos/cust-logo-double11-gray.svg"
              width={50}
              height={50}
            />
          </Link>
        </div>
      </div>
    </div>
  );
}

export function CustomerLogosColored() {
  return (
    <>
      <div className="flex justify-center items-center p-8 mb-8">
        <h3 className="text-xl sm:text-3xl tracking-tight font-bold uppercase text-neutral-800">
          Trusted by organizations like
        </h3>
      </div>
      {/* Strangely, Safari has animation bugs with the default left direction */}
      <Marquee autoFill pauseOnHover direction="right">
        {/*
          Prop width/height match each logo's intrinsic ratio so Next/Image's
          aspect-ratio check is satisfied. Tailwind h-20 w-auto then scales
          every logo down to a uniform ~80px row height while keeping its
          natural aspect ratio (no squishing wide wordmarks into squares).
        */}
        <Link
          href="https://caktusgroup.com"
          className="mx-12 flex items-center"
        >
          <Image
            alt="caktus logo"
            src="/images/logos/cust-logo-caktus.png"
            width={426}
            height={234}
            className="h-20 w-auto"
          />
        </Link>
        <Link href="https://corrdyn.com" className="mx-12 flex items-center">
          <Image
            alt="corrdyn logo"
            src="/images/logos/cust-logo-corrdyn.svg"
            width={2879}
            height={304}
            className="h-20 w-auto"
          />
        </Link>
        <Link href="https://double11.co.uk" className="mx-12 flex items-center">
          <Image
            alt="double11 logo"
            src="/images/logos/cust-logo-double11.svg"
            width={1068}
            height={1182}
            className="h-20 w-auto"
          />
        </Link>
        <Link href="https://ipap.com" className="mx-12 flex items-center">
          <Image
            alt="ipap logo"
            src="/images/logos/cust-logo-ipap.png"
            width={300}
            height={146}
            className="h-20 w-auto"
          />
        </Link>
        <Link href="https://mst.nl" className="mx-12 flex items-center">
          <Image
            alt="mst logo"
            src="/images/logos/cust-logo-mst.svg"
            width={652}
            height={652}
            className="h-20 w-auto"
          />
        </Link>
        <Link href="https://nomobo.tv" className="mx-12 flex items-center">
          <Image
            alt="nomobo logo"
            src="/images/logos/cust-logo-nomobo.webp"
            width={392}
            height={337}
            className="h-20 w-auto"
          />
        </Link>
        <Link href="https://semicat.com" className="mx-12 flex items-center">
          <Image
            alt="semicat logo"
            src="/images/logos/cust-logo-semicat.png"
            width={737}
            height={227}
            className="h-20 w-auto"
          />
        </Link>
        <Link
          href="https://square1.io"
          className="mx-12 flex items-center bg-neutral-950 p-4 rounded-sm"
        >
          <Image
            alt="square1 logo"
            src="/images/logos/cust-logo-square1.svg"
            width={164}
            height={31}
            className="h-20 w-auto"
          />
        </Link>
        <Link href="https://teracloud.com" className="mx-12 flex items-center">
          <Image
            alt="teracloud logo"
            src="/images/logos/cust-logo-teracloud.svg"
            width={191}
            height={22}
            className="h-20 w-auto"
          />
        </Link>
        <Link href="https://wolfram.com" className="mx-12 flex items-center">
          <Image
            alt="wolfram logo"
            src="/images/logos/cust-logo-wolfram.svg"
            width={198}
            height={156}
            className="h-20 w-auto"
          />
        </Link>
      </Marquee>
    </>
  );
}
