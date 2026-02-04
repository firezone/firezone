export default function Mission() {
  return (
    <section className="pt-12 bg-neutral-950">
      <div className="py-8 px-4 mx-auto max-w-screen-lg text-center lg:py-16 lg:px-6 sm:text-lg">
        <h2 className="uppercase mb-14 justify-center md:text-5xl text-4xl tracking-tight font-semibold text-neutral-100 leading-none">
          Our mission
        </h2>
        <p className="mb-8 text-4xl tracking-tight text-neutral-100 sm:px-16 xl:px-32">
          {"To "}
          <span className="text-primary-500">secure</span>
          {" the world's information and "}
          <span className="text-primary-500">restore</span>
          {" global trust in internet-connected systems."}
        </p>
      </div>
    </section>
  );
}
