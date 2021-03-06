#include "gen.h"

int rp_gen_init (rp_gen_t *handle, int unsigned index) {
    static char path_gen [] = "/dev/uio/gen";
    size_t len = strlen(path_gen)+1+1;
    char path[len];

    // a single character is reserved for the index
    // so indexes above 9 are an error
    if (index>9) {
        fprintf(stderr, "GEN: failed device index decimal representation is limited to 1 digit.\n");
        return (-1);
    }
    snprintf(path, "%s%u", len, path_gen, index);
    
    int status = rp_uio_init (&handle->uio, path);
    if (status) {
        return (-1);
    }
    // map regset
    handle->regset = (rp_gen_regset_t *) handle->uio.map[0].mem;
    // map table
    handle->table = (rp_gen_regset_t *) handle->uio.map[0].mem;

    return(0);
}

int rp_gen_release (rp_gen_t *handle) {
    // disable output
    rp_gen_set_enable(0);
    // reset hardware
    rp_gen_reset();

    int status = rp_uio_release (&(handle->uio));
    if (status) {
        return (-1);
    }

    return(0);
}




//    @property
//    def waveform (self):
//        """Waveworm array containing normalized values in the range [-1,1].
//
//        Array can be up to `buffer_size` samples in length.
//        """
//        siz = self.table_size
//        # TODO: nparray
//        return [self.table[i] / self._DWr for i in range(siz)]
//
//    @waveform.setter
//    def waveform (self, value):
//        siz = len(value)
//        if (siz <= self.buffer_size):
//            for i in range(siz):
//                # TODO add saturation
//                self.table[i] = int(value[i] * self._DWr)
//            self.table_size = siz
//        else:
//            raise ValueError("Waveform table size should not excede buffer size. buffer_size = {}".format(self.buffer_size))
//
//    class modes(Enum):
//        CONTINUOUS = 0x0
//        FINITE     = 0x1
//        INFINITE   = 0x3
//
//    @property
//    def mode (self) -> str:
//        """Generator mode:
//
//        * 'CONTINUOUS' - non burst mode for continuous/periodic signals
//        * 'FINITE'     - finite    length bursts
//        * 'INFINITE'   - inifinite length bursts
//        """
//        return (self.modes(self.regset.cfg_bmd))
//
//    @mode.setter
//    def mode (self, value: str):
//        if isinstance(value, str):
//            self.regset.cfg_bmd = self.modes[value].value
//        else:
//            raise ValueError("Generator supports modes ['CONTINUOUS', 'FINITE', 'INFINITE'].")
