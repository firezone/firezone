export default function Principles() {
  return (
    <section className="pt-12 bg-neutral-100">
      <div className="py-8 px-4 mx-auto max-w-screen-lg lg:py-16 lg:px-6">
        <h2 className="uppercase mb-14 justify-center md:text-5xl text-4xl tracking-tight font-semibold text-neutral-900 leading-none">
          OUR PRINCIPLES
        </h2>
        <div className="pt-12 grid grid-cols-1 md:grid-cols-5 gap-8">
          <div>
            <h3 className="uppercase text-lg tracking-tight font-semibold text-primary-500 leading-none">
              Transparency
            </h3>
            <p className="leading-6 tracking-tight text-lg py-8">
              Always be open and honest with our customers, partners, and
              employees. Never hide behind a wall of secrecy.
            </p>
          </div>
          <div>
            <h3 className="uppercase text-xl tracking-tight font-semibold text-primary-500 leading-none">
              Privacy
            </h3>
            <p className="leading-6 tracking-tight text-lg py-8">
              We maintain only the bare minimum of data required to operate the
              Firezone product and never sell or share it with third parties.
            </p>
          </div>
          <div>
            <h3 className="uppercase text-lg tracking-tight font-semibold text-primary-500 leading-none">
              Collaboration
            </h3>
            <p className="leading-6 tracking-tight text-lg py-8">
              {
                "We work together to achieve our goals, and celebrate our successes as a team. Everyone's voice is heard and respected."
              }
            </p>
          </div>
          <div>
            <h3 className="uppercase text-lg tracking-tight font-semibold text-primary-500 leading-none">
              Sensibility
            </h3>
            <p className="leading-6 tracking-tight text-lg py-8">
              {
                "We don't believe in hype or buzzwords. We believe in building products that solve real problems for real people."
              }
            </p>
          </div>
          <div>
            <h3 className="uppercase text-lg tracking-tight font-semibold text-primary-500 leading-none">
              Plurality
            </h3>
            <p className="leading-6 tracking-tight text-lg py-8">
              The best ideas come from a diverse set of backgrounds and
              experiences. We strive to build a team that reflects the world we
              live in.
            </p>
          </div>
        </div>
      </div>
    </section>
  );
}
