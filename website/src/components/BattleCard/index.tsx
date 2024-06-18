import Image from "next/image";
import { HiCheck, HiXMark } from "react-icons/hi2";

export default function BattleCard() {
  return (
    <div className="sm:mx-auto px-4">
      <h2 className="text-2xl md:text-4xl tracking-tight font-bold sm:justify-center mb-8 md:mb-16">
        See how Firezone compares
      </h2>

      <div className="max-w-screen-lg mx-auto sm:px-8">
        <div className="shadow-lg rounded mx-auto overflow-x-auto">
          <table className="border w-full text-left text-neutral-900 text-sm md:text-md lg:text-lg">
            <thead>
              <tr className="border-b bg-primary-50 border-primary-300">
                <th className="px-3 sm:px-6 py-3"></th>
                <th className="text-center px-3 sm:px-6 py-3">Twingate</th>
                <th className="text-center px-3 sm:px-6 py-3">Tailscale</th>
                <th className="text-center px-3 sm:px-6 py-3 bg-primary-200">
                  <span className="flex justify-center items-center">
                    <Image
                      src="/images/logo-main.svg"
                      width={50}
                      height={50}
                      alt="Firezone logo"
                      className="w-9 mr-2"
                    />
                    <span className="hidden sm:flex">Firezone</span>
                  </span>
                </th>
              </tr>
            </thead>
            <tbody>
              <tr className="border-b bg-neutral-50">
                <td className="px-3 sm:px-6 py-5 font-medium">Open source</td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiXMark className="mx-auto text-red-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5">Partial</td>
                <td className="text-center px-3 sm:px-6 py-5 bg-primary-100">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
              </tr>
              <tr className="border-b">
                <td className="px-3 sm:px-6 py-5 font-medium">
                  Built on WireGuard®
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiXMark className="mx-auto text-red-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5 bg-primary-100">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
              </tr>
              <tr className="border-b bg-neutral-50">
                <td className="px-3 sm:px-6 py-5 font-medium">
                  Load balancing
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5">Partial</td>
                <td className="text-center px-3 sm:px-6 py-5 bg-primary-100">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
              </tr>
              <tr className="border-b">
                <td className="px-3 sm:px-6 py-5 font-medium">
                  Automatic failover
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5 bg-primary-100">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
              </tr>
              <tr className="border-b bg-neutral-50">
                <td className="px-3 sm:px-6 py-5 font-medium">
                  NAT hole-punching
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5 bg-primary-100">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
              </tr>
              <tr className="border-b">
                <td className="px-3 sm:px-6 py-5 font-medium">
                  Resource-level access policies
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5 bg-primary-100">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
              </tr>
              <tr className="border-b bg-neutral-50">
                <td className="px-3 sm:px-6 py-5 font-medium">
                  Google directory sync
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiXMark className="mx-auto text-red-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5 bg-primary-100">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
              </tr>
              <tr className="border-b">
                <td className="px-3 sm:px-6 py-5 font-medium">
                  Entra directory sync
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5 bg-primary-100">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
              </tr>
              <tr className="border-b bg-neutral-50">
                <td className="px-3 sm:px-6 py-5 font-medium">
                  Okta directory sync
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5 bg-primary-100">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
              </tr>
              <tr className="border-b bg-neutral-50">
                <td className="px-3 sm:px-6 py-5 font-medium">
                  JumpCloud directory sync
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiXMark className="mx-auto text-red-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5 bg-primary-100">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
              </tr>
              <tr className="border-b">
                <td className="px-3 sm:px-6 py-5 font-medium">
                  DNS-based routing
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5">Partial</td>
                <td className="text-center px-3 sm:px-6 py-5 bg-primary-100">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
              </tr>
              <tr className="border-b bg-neutral-50">
                <td className="px-3 sm:px-6 py-5 font-medium">
                  Mesh networking
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiXMark className="mx-auto text-red-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5 bg-primary-100">
                  <HiXMark className="mx-auto text-red-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
              </tr>
              <tr className="border-b">
                <td className="px-3 sm:px-6 py-5 font-medium">
                  Annual invoicing
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
                <td className="text-center px-3 sm:px-6 py-5 bg-primary-100">
                  <HiCheck className="mx-auto text-green-600 flex-shrink-0 w-6 h-6 md:w-8 md:h-8" />
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p className="text-neutral-900 text-right text-xs my-4">
          <i>Last updated: 4/22/2024</i>
        </p>
      </div>
    </div>
  );
}
