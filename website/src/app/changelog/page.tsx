import { Metadata } from "next";
import Changelog from "@/components/Changelog";

export const metadata: Metadata = {
  title: "Changelog • Firezone",
  description: "A list of the most recent updates to Firezone.",
};

export default function Page() {
  return (
    <>
      <section className="py-8 px-4 mx-auto max-w-md md:max-w-screen-md lg:py-16 lg:px-6">
        <div className="mx-auto max-w-screen-sm text-center">
          <h1 className="justify-center mb-4 text-3xl lg:text-6xl tracking-tight font-extrabold text-neutral-900 ">
            Changelog
          </h1>
          <p className="text-neutral-900 text-lg sm:text-xl ">
            A list of the most recent updates to Firezone, organized by
            component.
          </p>
        </div>
      </section>
      <Changelog />
    </>
  );
}
