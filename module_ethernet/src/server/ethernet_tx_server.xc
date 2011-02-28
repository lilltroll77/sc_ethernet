#include "smi.h"
#include "mii.h"
#include "mii_queue.h"
#include "ethernet_server_def.h"
#include "eth_phy.h"
#include <print.h>
#include <xs1.h>
#include <xclib.h>

#ifdef AVB_MAC
#include "avb_1722_router_table.h"
#endif

#define MAX_LINKS 10

#define LINK_POLL_PERIOD 10000000

void checkLink(smi_interface_t &smi,
               int linkNum,
               chanend c,
               int &phy_status)
{
  int new_status = eth_phy_checklink(smi);
  if (new_status != phy_status) {
    outuchar(c, linkNum);
    outuchar(c, new_status);
    outuchar(c, 0);
    outct(c, XS1_CT_END);
    //    inct(c, XS1_CT_END);
    phy_status = new_status;
  }
}
#pragma unsafe arrays
void ethernet_tx_server(mii_queue_t &free_queue,
                        mii_queue_t &out_q1,
                        mii_queue_t &out_q2,
                        int num_q,
                        mii_queue_t &ts_queue,
                        mii_packet_t buf[], 
                        const int mac_addr[2],
                        chanend tx[],
                        int num_tx,
                        smi_interface_t &?smi1, 
                        smi_interface_t &?smi2, 
                        chanend ?connect_status) 
{
  int k;
  int enabled[MAX_LINKS];
  int pendingCmd[MAX_LINKS]={0};
  timer tmr;
  unsigned linkCheckTime = 0;
  int phy_status[2] = {0};
  
  tmr :> linkCheckTime;
  linkCheckTime += LINK_POLL_PERIOD;


  for (int i=0;i<num_tx;i++) 
    enabled[i] = 1;

  while (1) {
    for (int i=0;i<num_tx;i++) {
      int cmd = pendingCmd[i];
      int k=0;
      int length, dst_port;
      switch (cmd) 
        {
        case ETHERNET_TX_REQ:
        case ETHERNET_TX_REQ_OFFSET2:
        case ETHERNET_TX_REQ_TIMED:      
          k = get_queue_entry(free_queue);
          if (k) {            
  
            if (cmd == ETHERNET_TX_REQ_TIMED)
              buf[k].timestamp_id = i+1;
            else
              buf[k].timestamp_id = 0;              
            

            if (cmd == ETHERNET_TX_REQ_OFFSET2) {
              master {                          
                tx[i] :> length;
                tx[i] :> dst_port;
                tx[i] :> char;
                tx[i] :> char;
                buf[k].length = length;
                for(int j=0;j<(length+3)>>2;j++) {
                  int datum;
                  tx[i] :> datum;
                  buf[k].data[j] = byterev(datum);  
                }
                tx[i] :> char;
                tx[i] :> char;
              }
              cmd = ETHERNET_TX_REQ;
            }
            else {
              master {          
                tx[i] :> length;
                tx[i] :> dst_port;
                buf[k].length = length;
                for(int j=0;j<(length+3)>>2;j++)
                  tx[i] :> buf[k].data[j];  
              }
            }

            buf[k].complete = 1;
            
            
            if (dst_port == 0 || num_q == 1) {              
              add_queue_entry(out_q1, k);
            }
            else if (dst_port == ETH_BROADCAST) {
              set_transmit_count(k, 1);       
              add_queue_entry(out_q1, k);
              add_queue_entry(out_q2, k);                     
            }
            else
              add_queue_entry(out_q2, k);
            
            enabled[i] = 0;
            pendingCmd[i] = 0;
          }
          break;
        default:
          break;
          
        }
    }

    select {
      case tmr when timerafter(linkCheckTime) :> int:
        if (!isnull(smi1) && !isnull(connect_status)) {
          checkLink(smi1, 0, connect_status, phy_status[0]);
        }
        if (!isnull(smi2) && !isnull(connect_status)) {
          checkLink(smi2, 1, connect_status, phy_status[1]);
        }       
        linkCheckTime += LINK_POLL_PERIOD;
      break;
         case (int i=0;i<num_tx;i++) enabled[i] => tx[i] :> int cmd:
           {         
          switch (cmd) 
            {
            case ETHERNET_TX_REQ:
            case ETHERNET_TX_REQ_OFFSET2:
            case ETHERNET_TX_REQ_TIMED:      
              pendingCmd[i] = cmd;
              break;
            case ETHERNET_GET_MAC_ADRS:
              slave {
                for (int j=0;j< 6;j++) {
                  tx[i] <: (char) (mac_addr,char[])[j];
                }
              }
              break;
#ifdef AVB_MAC
        case ETHERNET_TX_UPDATE_AVB_ROUTER:
          { unsigned key0, key1, link, hash;
            master {
              tx[i] :> key0;
              tx[i] :> key1;
              tx[i] :> link;
              tx[i] :> hash;
            }
            avb_1722_router_table_add_entry(key0, key1, link, hash);
          }
          break;
        case ETHERNET_TX_INIT_AVB_ROUTER:
            init_avb_1722_router_table();
          break;
#endif
            default:
              // Unrecognized command
              break;
            }
          break;
           }
    default:
      for (int i=0;i<num_tx;i++) 
        enabled[i] = 1; 
      break;
    }
    k=get_queue_entry(ts_queue);
    if (k != 0) {
      int i = buf[k].timestamp_id;
      tx[i-1] <: buf[k].timestamp;
      if (get_and_dec_transmit_count(k) == 0) 
        free_queue_entry(k);        
    }
  }
}
