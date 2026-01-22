import Link from "next/link";
import { LinkedInIcon, GitHubIcon, XIcon } from "@/components/Icons";

export default function Contact() {
  return (
    <section className="border-t border-neutral-200 bg-neutral-100">
      <div className="py-8 px-4 mx-auto max-w-screen-lg lg:py-16 lg:px-6">
        <h2 className="text-2xl sm:text-3xl font-semibold text-neutral-900 tracking-tight">
          Contact us:
        </h2>
        <table className="mt-8 text-left rounded-sm">
          <tbody>
            <tr className="border-b border-neutral-200">
              <td className="py-2 px-3">
                <strong>Media Inquiries:</strong>
              </td>
              <td className="py-2 px-3">
                <Link
                  href={new URL("mailto:media@firezone.dev")}
                  className="text-accent-500 hover:underline"
                >
                  media@firezone.dev
                </Link>
              </td>
            </tr>
            <tr className="border-b border-neutral-200">
              <td className="py-2 px-3">
                <strong>Other Inquiries:</strong>
              </td>
              <td className="py-2 px-3">
                <Link
                  href={new URL("mailto:support@firezone.dev")}
                  className="text-accent-500 hover:underline"
                >
                  support@firezone.dev
                </Link>
              </td>
            </tr>
            <tr className="border-b border-neutral-200">
              <td className="py-2 px-3">
                <strong>Social:</strong>
              </td>
              <td className="py-2 px-3 flex space-x-2">
                <XIcon url={new URL("https://x.com/firezonehq")} />
                <GitHubIcon url={new URL("https://github.com/firezone")} />
                <LinkedInIcon
                  url={new URL("https://linkedin.com/company/firezonehq")}
                />
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
  );
}
