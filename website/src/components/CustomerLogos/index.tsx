import Image from "next/image";
import Link from "next/link";
import Marquee from "react-fast-marquee";

export default function CustomerLogos() {
  return (
    <>
      <div className="flex justify-center items-center p-8 mb-8">
        <h3 className="text-xl sm:text-3xl tracking-tight font-bold uppercase text-neutral-800">
          Trusted by organizations like
        </h3>
      </div>
      {/* Strangely, Safari has animation bugs with the default left direction */}
      <Marquee autoFill pauseOnHover direction="right">
        <Link href="https://bunq.com" className="mx-12 flex items-center">
          <Image
            alt="bunq logo"
            src="/images/cust-logo-bunq.svg"
            width={150}
            height={150}
          />
        </Link>
        <Link
          href="https://caktusgroup.com"
          className="mx-12 flex items-center"
        >
          <Image
            alt="caktus logo"
            src="/images/cust-logo-caktus.png"
            width={150}
            height={150}
          />
        </Link>
        <Link href="https://corrdyn.com" className="mx-12 flex items-center">
          <Image
            alt="corrdyn logo"
            src="/images/cust-logo-corrdyn.svg"
            width={150}
            height={150}
          />
        </Link>
        <Link href="https://double11.co.uk" className="mx-12 flex items-center">
          <Image
            alt="double11 logo"
            src="/images/cust-logo-double11.svg"
            width={150}
            height={150}
          />
        </Link>
        <Link href="https://ipap.com" className="mx-12 flex items-center">
          <Image
            alt="ipap logo"
            src="/images/cust-logo-ipap.png"
            width={150}
            height={150}
          />
        </Link>
        <Link href="https://mst.nl" className="mx-12 flex items-center">
          <Image
            alt="mst logo"
            src="/images/cust-logo-mst.svg"
            width={150}
            height={150}
          />
        </Link>
        <Link href="https://nomobo.tv" className="mx-12 flex items-center">
          <Image
            alt="nomobo logo"
            src="/images/cust-logo-nomobo.webp"
            width={150}
            height={150}
          />
        </Link>
        <Link href="https://sebgroup.com" className="mx-12 flex items-center">
          <Image
            alt="seb logo"
            src="/images/cust-logo-seb.svg"
            width={150}
            height={150}
          />
        </Link>
        <Link href="https://semicat.com" className="mx-12 flex items-center">
          <Image
            alt="semicat logo"
            src="/images/cust-logo-semicat.png"
            width={150}
            height={150}
          />
        </Link>
        <Link
          href="https://square1.io"
          className="mx-12 flex items-center bg-neutral-900 p-4 rounded"
        >
          <Image
            alt="square1 logo"
            src="/images/cust-logo-square1.svg"
            width={150}
            height={150}
          />
        </Link>
        <Link href="https://teracloud.com" className="mx-12 flex items-center">
          <Image
            alt="teracloud logo"
            src="/images/cust-logo-teracloud.svg"
            width={150}
            height={150}
          />
        </Link>
        <Link href="https://wolfram.com" className="mx-12 flex items-center">
          <Image
            alt="wolfram logo"
            src="/images/cust-logo-wolfram.svg"
            width={150}
            height={150}
          />
        </Link>
      </Marquee>
    </>
  );
}
