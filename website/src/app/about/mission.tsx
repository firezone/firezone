import Link from "next/link";

export default function Mission() {
  return (
    <section className="pt-12 bg-neutral-900">
      <div className="py-8 px-4 mx-auto max-w-screen-lg text-center lg:py-16 lg:px-6 sm:text-lg">
        <h2 className="mb-14 justify-center md:text-5xl text-4xl tracking-tight font-extrabold text-neutral-100 leading-none">
          OUR MISSION
        </h2>
        <p className="mb-8 text-2xl tracking-tight text-neutral-100 sm:px-16 xl:px-32">
          To reshape how humanity accesses computer resources, weaving{" "}
          <span className="text-primary-500">simplicity</span> and{" "}
          <span className="text-primary-500">security</span> into the fabric of
          global connectivity.
        </p>
      </div>
    </section>
  );
}
